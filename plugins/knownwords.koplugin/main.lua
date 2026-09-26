--[[--
Known words: LingQ-style word states while reading.

Every new or learning word on the page is filled with its state's color. Tap a
colored word (or look it up in the dictionary) to set its state: new, learning
levels 1 to 3, known or ignored. Stats show how many words you know, overall
and for the current book.

See doc/Known_words_plugin.md for the design.

@module koplugin.knownwords
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BookScan = require("bookscan")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Csv = require("csv")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local KeyValuePage = require("ui/widget/keyvaluepage")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local Overlay = require("overlay")
local PathChooser = require("ui/widget/pathchooser")
local SpinWidget = require("ui/widget/spinwidget")
local States = require("states")
local Store = require("store")
local Tokenizer = require("tokenizer")
local UIManager = require("ui/uimanager")
local Utf8Proc = require("ffi/utf8proc")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local Screen = Device.screen
local T = ffiUtil.template

Tokenizer.setLowercase(function(s) return Utf8Proc.lowercase(s) end)

local DB_PATH = DataStorage:getSettingsDir() .. "/known_words.sqlite3"

local DEFAULT_SETTINGS = {
    -- Books whose language is in this list are tracked automatically.
    languages = { "es" },
    -- Language for books that have none in their metadata but are turned on.
    default_lang = "es",
    -- Fill color per colored state, as Blitbuffer.HIGHLIGHT_COLORS names.
    colors = {
        ["0"] = States.DEFAULT_COLORS[0],
        ["1"] = States.DEFAULT_COLORS[1],
        ["2"] = States.DEFAULT_COLORS[2],
        ["3"] = States.DEFAULT_COLORS[3],
    },
    -- 0.1 (faint) to 1 (full color)
    intensity = 0.5,
    show_new = true,
    tap_words = true,
    lookup_sets_level1 = true,
    auto_known_on_turn = false,
}

-- Some books use three-letter language codes.
local ISO639_2 = {
    spa = "es", eng = "en", fra = "fr", fre = "fr", deu = "de", ger = "de",
    ita = "it", por = "pt", nld = "nl", dut = "nl", rus = "ru", pol = "pl",
    cat = "ca", swe = "sv",
}

local COLOR_CHOICES = { "red", "orange", "yellow", "green", "olive", "cyan", "blue", "purple" }
local COLOR_NAMES = {
    red = _("Red"), orange = _("Orange"), yellow = _("Yellow"), green = _("Green"),
    olive = _("Olive"), cyan = _("Cyan"), blue = _("Blue"), purple = _("Purple"),
}

local KnownWords = WidgetContainer:extend{
    name = "knownwords",
    is_doc_only = true,
}

function KnownWords:init()
    self.settings = G_reader_settings:readSetting("knownwords", {})
    for k, v in pairs(DEFAULT_SETTINGS) do
        if self.settings[k] == nil then
            self.settings[k] = type(v) == "table" and util.tableDeepCopy(v) or v
        end
    end
    self.states = {}
    self.read_pages = {}
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function KnownWords:onDispatcherRegisterActions()
    Dispatcher:registerAction("knownwords_mark_page_known", {
        category = "none", event = "KnownWordsMarkPageKnown",
        title = _("Known words: mark new words on page as known"), reader = true,
    })
    Dispatcher:registerAction("knownwords_show_stats", {
        category = "none", event = "KnownWordsShowStats",
        title = _("Known words: statistics"), reader = true,
    })
    Dispatcher:registerAction("knownwords_toggle_colors", {
        category = "none", event = "KnownWordsToggleColors",
        title = _("Known words: show or hide colors"), reader = true,
    })
end

-- Lifecycle -------------------------------------------------------------------

function KnownWords:onReaderReady()
    if not self.ui.rolling then return end -- reflowable books only
    self.md5 = self.ui.doc_settings:readSetting("partial_md5_checksum")
    self.title = self.ui.doc_props and self.ui.doc_props.display_title
    local ok, store = pcall(Store.open, DB_PATH, Device:canUseWAL())
    if not ok then
        logger.warn("KnownWords: cannot open database:", store)
        return
    end
    self.store = store
    self.overlay = Overlay:new{ plugin = self }
    self.view:registerViewModule("knownwords", self.overlay)
    self:setupTouchZones()
    self:registerDictButtons()
    self:applyBookMode()
end

function KnownWords:onCloseDocument()
    if self.scan then self.scan:cancel() end
    if self.store then
        self.store:close()
        self.store = nil
    end
end

-- Resolves the book's language and whether words are tracked in it, then
-- loads the states (re-run when the per-book setting changes).
function KnownWords:applyBookMode()
    local book_lang = self:getBookLanguage()
    local mode = self.ui.doc_settings:readSetting("knownwords_mode") -- nil (auto), "on" or "off"
    if mode == "on" then
        self.enabled = true
    elseif mode == "off" then
        self.enabled = false
    else
        self.enabled = book_lang ~= nil and self:isTrackedLanguage(book_lang)
    end
    self.lang = book_lang or self.settings.default_lang
    self.states = self.enabled and self.store:loadStates(self.lang) or {}
    self.overlay:invalidate()
    if self.enabled then
        self:startBookScanIfNeeded()
    elseif self.scan then
        self.scan:cancel()
        self.scan = nil
    end
    UIManager:setDirty(self.view.dialog, "ui")
end

function KnownWords:getBookLanguage()
    local lang = self.ui.doc_props and self.ui.doc_props.language
    if type(lang) ~= "string" then return nil end
    lang = lang:lower():match("^%a+")
    if not lang then return nil end
    return ISO639_2[lang] or lang
end

function KnownWords:isTrackedLanguage(lang)
    for _, l in ipairs(self.settings.languages) do
        if l == lang then return true end
    end
    return false
end

function KnownWords:isActive()
    return self.enabled and self.store ~= nil and not self.hidden
end

function KnownWords:saveSettings()
    G_reader_settings:saveSetting("knownwords", self.settings)
    self.fill_styles = nil
end

function KnownWords:refreshPage()
    UIManager:setDirty(self.view.dialog, "ui")
end

-- Fill styles -----------------------------------------------------------------

--- Returns the fill style of each state that is colored on the page.
function KnownWords:getFillStyles()
    local use_color = Screen:isColorEnabled()
    if self.fill_styles and self.fill_styles_color == use_color then
        return self.fill_styles
    end
    local styles = {}
    for state = 0, 3 do
        if state ~= States.NEW or self.settings.show_new then
            if use_color then
                styles[state] = self:getColorStyle(state)
            elseif state == States.NEW then
                styles[state] = { underline = true }
            else
                styles[state] = { darken = States.GRAY_DARKEN[state] }
            end
        end
    end
    self.fill_styles, self.fill_styles_color = styles, use_color
    return styles
end

-- Returns the color of a state, lightened toward white by the intensity setting.
function KnownWords:getStateColor(state, intensity)
    local name = self.settings.colors[tostring(state)] or States.DEFAULT_COLORS[state]
    local c = Blitbuffer.colorFromString(Blitbuffer.HIGHLIGHT_COLORS[name] or Blitbuffer.HIGHLIGHT_COLORS.yellow)
    intensity = intensity or self.settings.intensity
    local function lighten(v) return math.floor(255 - (255 - v) * intensity + 0.5) end
    return Blitbuffer.ColorRGB32(lighten(c.r), lighten(c.g), lighten(c.b), 0xFF), c
end

-- Background of a state's button: its page color (a bit lighter, for
-- readable labels), or nil for known and ignored, or without color.
function KnownWords:getButtonColor(state)
    if not (Screen:isColorEnabled() and States.isColored(state)) then return nil end
    return (self:getStateColor(state, 0.45))
end

function KnownWords:getColorStyle(state)
    local rgb, full = self:getStateColor(state)
    return {
        rgb = rgb,
        -- night mode blends the full color over the inverted page
        night = Blitbuffer.ColorRGB32(full.r, full.g, full.b, math.floor(0xFF * 0.4 * self.settings.intensity + 0.5)):invert(),
    }
end

-- Word states -------------------------------------------------------------------

function KnownWords:getState(word)
    return self.states[word] or States.NEW
end

--- Sets a word's state, saves it and repaints the page.
function KnownWords:setWordState(word, state, info)
    info = info or {}
    info.book_md5 = self.md5
    info.book_title = self.title
    self.store:setState(self.lang, word, state, info)
    self.states[word] = state ~= States.NEW and state or nil
    self:refreshPage()
end

-- Returns the sentence around a word of the page.
function KnownWords:getContext(page_word)
    if not (page_word and page_word.pos0 and page_word.pos1) then return nil end
    local ok, prev, next = pcall(self.ui.document.getSelectedWordContext, self.ui.document,
        page_word.raw, 25, page_word.pos0, page_word.pos1)
    if not ok then return nil end
    return Tokenizer.sentence(prev, page_word.raw, next)
end

function KnownWords:onKnownWordsMarkPageKnown()
    if not self:isActive() then return true end
    local page = self.overlay:getCurrentCachedPage() or self.overlay:getPage()
    local words = {}
    for _, w in ipairs(page.words) do
        if self:getState(w.word) == States.NEW then
            words[#words + 1] = w.word
        end
    end
    local changed = self.store:setStates(self.lang, words, States.KNOWN,
        { only_from = States.NEW, kind = "page_known", book_md5 = self.md5, book_title = self.title })
    for _, word in ipairs(changed) do
        self.states[word] = States.KNOWN
    end
    Notification:notify(T(N_("1 word marked as known", "%1 words marked as known", #changed), #changed))
    self:refreshPage()
    return true
end

function KnownWords:onKnownWordsToggleColors()
    self.hidden = not self.hidden
    self:refreshPage()
    return true
end

-- Page turns ------------------------------------------------------------------

function KnownWords:onPageUpdate(new_page)
    if not self:isActive() or not new_page then return end
    local old = self.overlay.cache
    if not old or old.render_hash ~= self.ui.document:getDocumentRenderingHash(false) then return end
    if new_page ~= old.page + old.page_count then return end -- only a turn to the next page
    if not self.read_pages[old.key] then
        self.read_pages[old.key] = true
        self.store:addRead(self.lang, #old.words, 1)
    end
    if self.settings.auto_known_on_turn then
        local words = {}
        for _, w in ipairs(old.words) do
            if self:getState(w.word) == States.NEW then
                words[#words + 1] = w.word
            end
        end
        if #words > 0 then
            local changed = self.store:setStates(self.lang, words, States.KNOWN,
                { only_from = States.NEW, kind = "auto_known", book_md5 = self.md5, book_title = self.title })
            for _, word in ipairs(changed) do
                self.states[word] = States.KNOWN
            end
        end
    end
end

-- Tap on a word -------------------------------------------------------------------

function KnownWords:setupTouchZones()
    if not Device:isTouchDevice() then return end
    self.ui:registerTouchZones({
        {
            id = "knownwords_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = {
                "tap_top_left_corner",
                "tap_top_right_corner",
                "tap_left_bottom_corner",
                "tap_right_bottom_corner",
                "readerfooter_tap",
                "readerconfigmenu_ext_tap",
                "readerconfigmenu_tap",
                "readermenu_ext_tap",
                "readermenu_tap",
                "tap_forward",
                "tap_backward",
            },
            handler = function(ges) return self:onTapWord(ges) end,
        },
    })
end

function KnownWords:onTapWord(ges)
    if not self.settings.tap_words or not self:isActive() or self.view.view_mode ~= "page" then return end
    local highlight = self.ui.highlight
    if highlight and (highlight.select_mode or highlight.hold_pos) then return end
    local page_word = self.overlay:wordAt(ges.pos)
    if not page_word then return end
    local state = self:getState(page_word.word)
    -- Only colored words open the panel: taps elsewhere still turn pages.
    if not self:getFillStyles()[state] then return end
    -- Links keep working (crengine returns "" when there is none).
    local href = self.ui.document:getLinkFromPosition(ges.pos)
    if href and href ~= "" then return end
    self:showWordPanel(page_word.word, page_word)
    return true
end

--[[--
Shows the word panel: state buttons, meaning, notes and context.

@string word normalized word
@tparam[opt] table page_word the word on the page (for its context and position)
@func[opt] on_change called after a change (the vocabulary list refreshes with it)
--]]
function KnownWords:showWordPanel(word, page_word, on_change)
    local row = self.store:getWord(self.lang, word)
    local state = row and row.state or States.NEW
    local context = row and row.context or self:getContext(page_word)

    local lines = { word .. "  ·  " .. States.NAMES[state] }
    if row and row.meaning then
        table.insert(lines, T(_("Meaning: %1"), row.meaning))
    end
    if row and row.notes then
        table.insert(lines, T(_("Notes: %1"), row.notes))
    end
    if context and context ~= "" then
        table.insert(lines, "“" .. context .. "”")
    end

    local dialog
    local function done()
        UIManager:close(dialog)
        if on_change then on_change() end
    end
    local use_color = Screen:isColorEnabled()
    local state_row = {}
    for _, s in ipairs(States.ORDER) do
        local label = States.SHORT[s]
        if s == state then label = "✓ " .. label end
        state_row[#state_row + 1] = {
            text = label,
            background = self:getButtonColor(s),
            callback = function()
                self:setWordState(word, s, { context = context })
                done()
            end,
        }
    end
    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        title_align = "left",
        colorful = use_color,
        buttons = {
            state_row,
            {
                {
                    text = _("Dictionary"),
                    enabled = self.ui.dictionary ~= nil,
                    callback = function()
                        UIManager:close(dialog)
                        -- Come back to this panel when the dictionary closes.
                        self.ui.dictionary:onLookupWord(page_word and page_word.raw or word, true,
                            page_word and page_word.boxes, nil, nil, function()
                                self:showWordPanel(word, page_word, on_change)
                            end)
                    end,
                },
                {
                    text = _("Meaning…"),
                    callback = function()
                        UIManager:close(dialog)
                        self:editField(word, "meaning", row and row.meaning, function()
                            self:showWordPanel(word, page_word, on_change)
                        end)
                    end,
                },
                {
                    text = _("Notes…"),
                    callback = function()
                        UIManager:close(dialog)
                        self:editField(word, "notes", row and row.notes, function()
                            self:showWordPanel(word, page_word, on_change)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function KnownWords:editField(word, field, value, after)
    local input
    input = InputDialog:new{
        title = field == "meaning" and T(_("Meaning of %1"), word) or T(_("Notes for %1"), word),
        input = value or "",
        allow_newline = field == "notes",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(input)
                    after()
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local text = input:getInputText()
                    if field == "meaning" then
                        self.store:setMeaning(self.lang, word, text)
                    else
                        self.store:setNotes(self.lang, word, text)
                    end
                    UIManager:close(input)
                    after()
                end,
            },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

-- Dictionary popup ------------------------------------------------------------------

-- Returns the normalized word of a dictionary popup, or false if it is not a
-- single word. The first call per popup also records the lookup.
function KnownWords:getPopupWord(dict_popup)
    if dict_popup._knownwords_word == nil then
        local word = not dict_popup.is_wiki and Tokenizer.normalizeWord(dict_popup.word) or nil
        dict_popup._knownwords_word = word or false
        if word then
            self:recordLookup(word)
        end
    end
    return dict_popup._knownwords_word
end

function KnownWords:recordLookup(word)
    local context
    local highlight = self.ui.highlight
    if highlight and highlight.selected_text and highlight.selected_text.pos0 then
        local ok, prev, next = pcall(highlight.getSelectedWordContext, highlight, 25)
        if ok then
            context = Tokenizer.sentence(prev, highlight.selected_text.text or word, next)
        end
    end
    self.store:logLookup(self.lang, word, { context = context, book_md5 = self.md5, book_title = self.title })
    if self.settings.lookup_sets_level1 and self:getState(word) == States.NEW then
        self:setWordState(word, States.LEVEL1, { kind = "lookup_level1", context = context })
    end
end

-- Stock KOReader builds drop a plugin button's background in the dictionary
-- popup (this fork passes it through itself). Pass it through there too, so
-- the plugin alone shows colored state buttons on an unmodified install.
local function patchDictButtonBackgrounds()
    local DictQuickLookup = require("ui/widget/dictquicklookup")
    local populate = DictQuickLookup.populatePluginButtons
    if not populate or DictQuickLookup._knownwords_patched then return end
    DictQuickLookup._knownwords_patched = true
    DictQuickLookup.populatePluginButtons = function(dict_popup, pool, default_layout, extra_layout)
        populate(dict_popup, pool, default_layout, extra_layout)
        local specs = dict_popup.ui and dict_popup.ui.dictionary and dict_popup.ui.dictionary._dict_buttons
        for id, spec in pairs(specs or {}) do
            if spec.background and pool[id] and pool[id].background == nil then
                pool[id].background = spec.background
            end
        end
    end
end

function KnownWords:registerDictButtons()
    if not self.ui.dictionary then return end
    patchDictButtonBackgrounds()
    local function label(s, current)
        return s == current and "✓ " .. States.SHORT[s] or States.SHORT[s]
    end
    for _, s in ipairs(States.ORDER) do
        local spec
        spec = {
            id = "knownwords_s" .. s,
            conditional = true,
            row_group = "knownwords",
            -- Button calls text_func without the popup, so the label is set
            -- here: DictQuickLookup reads spec.text right after show_func.
            show_func = function(dict_popup)
                local word = self:isActive() and self:getPopupWord(dict_popup)
                if not word then return false end
                spec.text = label(s, self:getState(word))
                spec.background = self:getButtonColor(s)
                return true
            end,
            callback = function(dict_popup)
                local word = self:getPopupWord(dict_popup)
                if not word then return end
                self:setWordState(word, s)
                local buttons = dict_popup.button_table and dict_popup.button_table.button_by_id
                if buttons then
                    for _, other in ipairs(States.ORDER) do
                        local button = buttons["knownwords_s" .. other]
                        if button then button:setText(label(other, s), button.width) end
                    end
                    UIManager:setDirty(dict_popup, "ui")
                end
            end,
        }
        self.ui.dictionary:addToDictButtons(spec)
    end
end

-- Book scan ---------------------------------------------------------------------

function KnownWords:startBookScanIfNeeded(force)
    if not self.md5 then return end
    local book = self.store:getBook(self.md5)
    if not force and book and book.tokenizer_version == Tokenizer.VERSION and book.lang == self.lang then
        return
    end
    if self.scan and self.scan.running then return end
    self.scan = BookScan:new{
        ui = self.ui,
        on_done = function(counts, total)
            if self.store then
                self.store:saveBookScan(self.md5, self.title, self.lang, counts, total, Tokenizer.VERSION)
            end
        end,
    }
    self.scan:start()
end

-- Stats ---------------------------------------------------------------------------

local function pct(v)
    return string.format("%.1f %%", v)
end

function KnownWords:getPageStats()
    local page = self.overlay and self.overlay:getCurrentCachedPage()
    if not page or #page.words == 0 then return nil end
    local known, base = 0, 0
    for _, w in ipairs(page.words) do
        local s = self:getState(w.word)
        if s ~= States.IGNORED then
            base = base + 1
            if s == States.KNOWN then known = known + 1 end
        end
    end
    return base > 0 and 100 * known / base or 0
end

function KnownWords:onKnownWordsShowStats()
    if not self.store then return true end
    local counts = self.store:stateCounts(self.lang)
    local kv = {
        { _("Language"), self.lang },
        { _("Known words"), counts[States.KNOWN] },
        { _("Learning (levels 1 / 2 / 3)"), T("%1 / %2 / %3", counts[1], counts[2], counts[3]) },
        { _("Ignored"), counts[States.IGNORED] },
        "----",
    }
    if not self.enabled then
        table.insert(kv, { _("This book"), _("not tracked") })
    else
        local book = self.store:getBook(self.md5)
        local stats = book and book.lang == self.lang and self.store:bookStats(self.md5, self.lang)
        if self.scan and self.scan.running then
            table.insert(kv, { _("This book"), T(_("scanning… %1 %"), math.floor(100 * self.scan:progress())) })
        elseif not stats then
            table.insert(kv, { _("This book"), _("not scanned yet") })
        end
        if stats then
            table.insert(kv, { _("Known, unique words"), T("%1 (%2 / %3)", pct(stats.known_unique_pct),
                stats.known_unique, stats.unique - stats.ignored_unique) })
            table.insert(kv, { _("Known, running text"), pct(stats.known_running_pct) })
            table.insert(kv, { _("Learning, unique words"), T("%1 (%2)", pct(stats.learning_unique_pct), stats.learning_unique) })
            table.insert(kv, { _("New, unique words"), T("%1 (%2)", pct(stats.new_unique_pct), stats.new_unique) })
            table.insert(kv, { _("Words in book"), T(_("%1 (%2 unique)"), stats.running, stats.unique) })
        end
        local page_pct = self:getPageStats()
        if page_pct then
            table.insert(kv, { _("Known on this page"), pct(page_pct) })
        end
    end
    table.insert(kv, "----")
    local days = self.store:activity(self.lang, 30)
    local today = days[#days]
    table.insert(kv, { _("Today: words read"), today.words_read })
    table.insert(kv, { _("Today: new known words"), today.new_known })
    table.insert(kv, { _("Today: lookups"), today.lookups })
    local week_known, week_read = 0, 0
    for i = math.max(1, #days - 6), #days do
        week_known = week_known + days[i].new_known
        week_read = week_read + days[i].words_read
    end
    table.insert(kv, { _("Last 7 days: new known words"), week_known })
    table.insert(kv, { _("Last 7 days: words read"), week_read })
    table.insert(kv, { _("Last 30 days by day"), "▸", callback = function()
        self:showDailyStats(days)
    end })

    UIManager:show(KeyValuePage:new{
        title = _("Known words"),
        kv_pairs = kv,
        value_align = "right",
    })
    return true
end

function KnownWords:showDailyStats(days)
    local kv = {}
    for i = #days, 1, -1 do
        local d = days[i]
        kv[#kv + 1] = { d.day, T(_("+%1 known · %2 total · %3 read · %4 lookups"),
            d.new_known, d.known_total, d.words_read, d.lookups) }
    end
    UIManager:show(KeyValuePage:new{
        title = _("Known words by day"),
        kv_pairs = kv,
        value_align = "right",
    })
end

-- Vocabulary list -------------------------------------------------------------------

function KnownWords:showVocabulary(filter_state)
    if not self.store then return end
    local menu
    local function buildItems()
        local items = {}
        for _, row in ipairs(self.store:listWords(self.lang, { state = filter_state })) do
            items[#items + 1] = {
                text = row.meaning and (row.word .. " — " .. row.meaning) or row.word,
                mandatory = States.NAMES[row.state],
                word = row.word,
            }
        end
        return items
    end
    local function title()
        return filter_state and T(_("Words: %1"), States.NAMES[filter_state]) or _("Words")
    end
    menu = Menu:new{
        title = title(),
        item_table = buildItems(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        single_line = true,
        title_bar_left_icon = "appbar.menu",
    }
    menu.onMenuChoice = function(_menu, item)
        self:showWordPanel(item.word, nil, function()
            menu:switchItemTable(title(), buildItems(), -1)
        end)
        return true
    end
    menu.onLeftButtonTap = function()
        local dialog
        local buttons = {{
            { text = _("All"), callback = function()
                UIManager:close(dialog)
                filter_state = nil
                menu:switchItemTable(title(), buildItems())
            end },
        }}
        local row = {}
        for _, s in ipairs(States.ORDER) do
            row[#row + 1] = { text = States.SHORT[s], callback = function()
                UIManager:close(dialog)
                filter_state = s
                menu:switchItemTable(title(), buildItems())
            end }
        end
        table.insert(buttons, row)
        dialog = ButtonDialog:new{ title = _("Show words"), buttons = buttons }
        UIManager:show(dialog)
    end
    menu.close_callback = function()
        UIManager:close(menu)
        self:refreshPage()
    end
    UIManager:show(menu)
end

-- Import and export ---------------------------------------------------------------------

function KnownWords:exportCsv()
    local rows = self.store:exportRows(self.lang)
    local path = filemanagerutil.getHomeFolder() .. "/known_words_" .. self.lang .. ".csv"
    local file, err = io.open(path, "w")
    if not file then
        UIManager:show(InfoMessage:new{ text = T(_("Could not write %1: %2"), path, err) })
        return
    end
    for _, row in ipairs(rows) do
        file:write(Csv.formatRow(row, #Store.EXPORT_HEADER), "\n")
    end
    file:close()
    UIManager:show(InfoMessage:new{
        text = T(N_("Exported 1 word to %2", "Exported %1 words to %2", #rows - 1), #rows - 1, path),
    })
end

function KnownWords:importCsv()
    UIManager:show(PathChooser:new{
        select_directory = false,
        path = filemanagerutil.getHomeFolder(),
        file_filter = function(filename) return filename:lower():match("%.csv$") ~= nil end,
        onConfirm = function(path)
            local file = io.open(path, "r")
            if not file then return end
            local text = file:read("*a")
            file:close()
            local result = self.store:importRows(self.lang, Csv.parse(text), Tokenizer.normalize)
            self.states = self.store:loadStates(self.lang)
            self:refreshPage()
            UIManager:show(InfoMessage:new{
                text = T(_("Imported into %1:\nAdded: %2\nUpdated: %3\nUnchanged: %4\nSkipped: %5"),
                    self.lang, result.added, result.updated, result.unchanged, result.skipped),
            })
        end,
    })
end

-- Speed test ---------------------------------------------------------------------

-- Measures collecting and painting the words of the current page, the main
-- cost this plugin adds to a page turn.
function KnownWords:runSpeedTest()
    if not self:isActive() then return end
    local runs = 5
    local collect_ms, paint_ms, n = 0, 0, 0
    local bb = Blitbuffer.new(Screen:getWidth(), Screen:getHeight(), Screen.bb:getType())
    for _ = 1, runs do
        self.overlay:invalidate()
        local t0 = time.monotonic()
        local page = self.overlay:getPage()
        local t1 = time.monotonic()
        self.overlay:paintTo(bb, 0, 0)
        local t2 = time.monotonic()
        collect_ms = collect_ms + time.to_ms(t1 - t0)
        paint_ms = paint_ms + time.to_ms(t2 - t1)
        n = #page.words
    end
    bb:free()
    UIManager:show(InfoMessage:new{
        text = T(_("Words on page: %1\nCollecting words: %2 ms\nPainting colors: %3 ms\n(average of %4 runs)"),
            n, math.floor(collect_ms / runs + 0.5), math.floor(paint_ms / runs + 0.5), runs),
    })
end

-- Menu ----------------------------------------------------------------------------

function KnownWords:genColorMenu(state)
    local items = {}
    for _, name in ipairs(COLOR_CHOICES) do
        items[#items + 1] = {
            text = COLOR_NAMES[name],
            checked_func = function() return self.settings.colors[tostring(state)] == name end,
            radio = true,
            callback = function()
                self.settings.colors[tostring(state)] = name
                self:saveSettings()
                self:refreshPage()
            end,
        }
    end
    return {
        text_func = function()
            return T("%1: %2", States.NAMES[state], COLOR_NAMES[self.settings.colors[tostring(state)]] or "")
        end,
        sub_item_table = items,
    }
end

function KnownWords:addToMainMenu(menu_items)
    menu_items.known_words = {
        text = _("Known words"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:genMenu() end,
    }
end

function KnownWords:genMenu()
    if not self.ui.rolling then
        return {{ text = _("Known words works with reflowable books (EPUB, FB2, HTML, TXT…)"), enabled = false }}
    end
    if not self.store then
        return {{ text = _("Known words could not open its database"), enabled = false }}
    end
    local mode_items = {
        { value = nil, text = T(_("Automatic (tracked languages: %1)"), table.concat(self.settings.languages, ", ")) },
        { value = "on", text = _("On") },
        { value = "off", text = _("Off") },
    }
    local mode_menu = {}
    for _, m in ipairs(mode_items) do
        mode_menu[#mode_menu + 1] = {
            text = m.text,
            radio = true,
            checked_func = function() return self.ui.doc_settings:readSetting("knownwords_mode") == m.value end,
            callback = function()
                self.ui.doc_settings:saveSetting("knownwords_mode", m.value)
                self:applyBookMode()
            end,
        }
    end
    return {
        {
            text = _("Statistics"),
            callback = function() self:onKnownWordsShowStats() end,
        },
        {
            text = _("Words"),
            callback = function() self:showVocabulary() end,
        },
        {
            text = _("Mark new words on this page as known"),
            enabled_func = function() return self:isActive() end,
            callback = function() self:onKnownWordsMarkPageKnown() end,
            separator = true,
        },
        {
            text_func = function()
                return T(_("This book: %1"), self.enabled and T(_("tracked (%1)"), self.lang) or _("not tracked"))
            end,
            sub_item_table = mode_menu,
        },
        {
            text = _("Settings"),
            sub_item_table = {
                {
                    text = _("Color new words"),
                    checked_func = function() return self.settings.show_new end,
                    callback = function()
                        self.settings.show_new = not self.settings.show_new
                        self:saveSettings()
                        self:refreshPage()
                    end,
                },
                self:genColorMenu(0),
                self:genColorMenu(1),
                self:genColorMenu(2),
                self:genColorMenu(3),
                {
                    text_func = function()
                        return T(_("Color intensity: %1 %"), math.floor(self.settings.intensity * 100 + 0.5))
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        UIManager:show(SpinWidget:new{
                            title_text = _("Color intensity"),
                            info_text = _("Lower is lighter, which keeps text easier to read on color e-ink."),
                            value = math.floor(self.settings.intensity * 100 + 0.5),
                            value_min = 10,
                            value_max = 100,
                            value_step = 5,
                            value_hold_step = 20,
                            unit = "%",
                            default_value = math.floor(DEFAULT_SETTINGS.intensity * 100),
                            callback = function(spin)
                                self.settings.intensity = spin.value / 100
                                self:saveSettings()
                                self:refreshPage()
                                touchmenu_instance:updateItems()
                            end,
                        })
                    end,
                    separator = true,
                },
                {
                    text = _("Tap colored words to open the word panel"),
                    help_text = _("Taps on uncolored text still turn pages."),
                    checked_func = function() return self.settings.tap_words end,
                    callback = function()
                        self.settings.tap_words = not self.settings.tap_words
                        self:saveSettings()
                    end,
                },
                {
                    text = _("Looking up a new word makes it level 1"),
                    checked_func = function() return self.settings.lookup_sets_level1 end,
                    callback = function()
                        self.settings.lookup_sets_level1 = not self.settings.lookup_sets_level1
                        self:saveSettings()
                    end,
                },
                {
                    text = _("Turning the page marks its new words as known"),
                    help_text = _("As in LingQ. Counts grow quickly, but include words you skimmed."),
                    checked_func = function() return self.settings.auto_known_on_turn end,
                    callback = function()
                        self.settings.auto_known_on_turn = not self.settings.auto_known_on_turn
                        self:saveSettings()
                    end,
                    separator = true,
                },
                {
                    text_func = function()
                        return T(_("Tracked languages: %1"), table.concat(self.settings.languages, ", "))
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:editLanguages(touchmenu_instance)
                    end,
                },
            },
        },
        {
            text = _("Import and export"),
            sub_item_table = {
                {
                    text = _("Export words to CSV"),
                    callback = function() self:exportCsv() end,
                },
                {
                    text = _("Import words from CSV"),
                    help_text = _("Columns: word, state (new, 1, 2, 3, known, ignored; empty means known), meaning. A header row is skipped."),
                    callback = function() self:importCsv() end,
                },
            },
        },
        {
            text = _("Tools"),
            sub_item_table = {
                {
                    text = _("Measure page speed"),
                    enabled_func = function() return self:isActive() end,
                    callback = function() self:runSpeedTest() end,
                },
                {
                    text = _("Rescan this book"),
                    enabled_func = function() return self:isActive() end,
                    callback = function()
                        self:startBookScanIfNeeded(true)
                        Notification:notify(_("Scanning book…"))
                    end,
                },
                {
                    text = _("Reset all word states"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = T(_("Delete all words, meanings and history for %1? This cannot be undone. Export first to keep a copy."), self.lang),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                self.store:deleteLanguage(self.lang)
                                self.states = {}
                                self:refreshPage()
                            end,
                        })
                    end,
                },
            },
        },
    }
end

function KnownWords:editLanguages(touchmenu_instance)
    local input
    input = InputDialog:new{
        title = _("Tracked languages"),
        description = _("Language codes separated by commas, e.g. es, fr. Books in these languages are tracked automatically. The first one is also used for books without a language."),
        input = table.concat(self.settings.languages, ", "),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(input) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local langs = {}
                    for code in input:getInputText():lower():gmatch("%a+") do
                        langs[#langs + 1] = ISO639_2[code] or code
                    end
                    if #langs > 0 then
                        self.settings.languages = langs
                        self.settings.default_lang = langs[1]
                        self:saveSettings()
                        self:applyBookMode()
                    end
                    UIManager:close(input)
                    touchmenu_instance:updateItems()
                end,
            },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

return KnownWords

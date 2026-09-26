--[[--
Page overlay for the Known words plugin: fills the box of every new and
learning word on the current page with its state's color.

Registered as a ReaderView view module, so it paints after the page. The words
of a page and their screen boxes are collected once from crengine and cached;
a state change only repaints fills and does not collect again.

Only reflowable documents (crengine) in page view mode are supported.

@module koplugin.knownwords.overlay
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local Size = require("ui/size")
local Tokenizer = require("tokenizer")
local logger = require("logger")
local time = require("ui/time")

-- Safety limit on words collected per page (a page holds a few hundred).
local MAX_WORDS_PER_PAGE = 4000

local Overlay = {}
Overlay.__index = Overlay

--- Creates the overlay. o.plugin is the Known words plugin instance.
function Overlay:new(o)
    return setmetatable(o or {}, self)
end

-- Identifies the current layout and page: any change of rendering, position,
-- or screen size invalidates the cached words.
function Overlay:pageKey()
    local doc = self.ui.document
    return table.concat({
        doc:getDocumentRenderingHash(false),
        doc:getCurrentPos(),
        doc:getCurrentPage(),
        Screen:getWidth(),
        Screen:getHeight(),
    }, "|")
end

--[[--
Collects the words of the current page from crengine.

@treturn table { key, page, page_count (visible pages), words = array of
{ word (normalized), raw, pos0, pos1, boxes (array of Geom) }, build_ms }
--]]
function Overlay:collect()
    local doc = self.ui.document
    local start_time = time.monotonic()
    local page = doc:getCurrentPage()
    local visible = doc:getVisiblePageNumberCount() or 1
    local start_xp = doc:getPageXPointer(page)
    local end_xp
    if page + visible <= doc:getPageCount() then
        end_xp = doc:getPageXPointer(page + visible)
    end

    -- getNextVisibleWordStart() skips a word starting exactly at its
    -- argument, so start from the character before the page start.
    local ws
    local prev_char = doc:getPrevVisibleChar(start_xp)
    if prev_char then
        ws = doc:getNextVisibleWordStart(prev_char)
    else
        ws = start_xp -- start of the document
    end

    local words = {}
    local count = 0
    while ws and count < MAX_WORDS_PER_PAGE do
        count = count + 1
        -- compareXPointers() returns 1 when end_xp is after ws
        if end_xp and doc:compareXPointers(ws, end_xp) ~= 1 then break end
        local we = doc:getNextVisibleWordEnd(ws)
        if not we then break end
        local raw = doc:getTextFromXPointers(ws, we)
        local word = Tokenizer.normalizeWord(raw)
        if word then
            local boxes = {}
            -- Word boxes (not line segments), in screen coordinates. A word
            -- hyphenated across lines has one box per line; parts that are
            -- not on this page have none.
            local word_boxes = doc._document:getWordBoxesFromPositions(ws, we, false)
            if word_boxes then
                for _, b in ipairs(word_boxes) do
                    if b.x1 > b.x0 and b.y1 > b.y0 then
                        boxes[#boxes + 1] = Geom:new{ x = b.x0, y = b.y0, w = b.x1 - b.x0, h = b.y1 - b.y0 }
                    end
                end
            end
            if #boxes > 0 then
                words[#words + 1] = { word = word, raw = raw, pos0 = ws, pos1 = we, boxes = boxes }
            end
        end
        ws = doc:getNextVisibleWordStart(we)
    end

    local build_ms = time.to_ms(time.monotonic() - start_time)
    logger.dbg("KnownWords: collected", #words, "words in", build_ms, "ms")
    return {
        page = page,
        page_count = visible,
        words = words,
        build_ms = build_ms,
    }
end

--- Returns the (cached) words of the current page.
function Overlay:getPage()
    local key = self:pageKey()
    if self.cache and self.cache.key == key then
        return self.cache
    end
    local page = self:collect()
    page.key = key
    page.render_hash = self.ui.document:getDocumentRenderingHash(false)
    self.cache = page
    return page
end

--- Forgets the cached page, so the next paint collects again.
function Overlay:invalidate()
    self.cache = nil
end

--- Returns the cached page if it is still the current one.
function Overlay:getCurrentCachedPage()
    if self.cache and self.cache.key == self:pageKey() then
        return self.cache
    end
end

local function fill(bb, rect, style)
    local x, y, w, h = rect.x, rect.y, rect.w, rect.h
    if style.rgb then
        if bb:getInverse() == 1 then
            -- Multiplying does not work on a dark background (night mode).
            bb:blendRectRGB32(x, y, w, h, style.night)
        else
            bb:multiplyRectRGB(x, y, w, h, style.rgb)
        end
    elseif style.darken then
        bb:darkenRect(x, y, w, h, style.darken)
    elseif style.underline then
        bb:paintRect(x, y + h - Size.line.thick, w, Size.line.thick, Blitbuffer.COLOR_DARK_GRAY)
    end
end
Overlay.fill = fill

--- Paints the fills; returns true when colors were used (ReaderView then enables color refresh).
function Overlay:paintTo(bb, x, y)
    local plugin = self.plugin
    if not plugin:isActive() or self.view.view_mode ~= "page" then return end
    local ok, page = pcall(self.getPage, self)
    if not ok then
        logger.warn("KnownWords: could not collect page words:", page)
        return
    end
    local styles = plugin:getFillStyles()
    local states = plugin.states
    local colorful = false
    for _, w in ipairs(page.words) do
        local style = styles[states[w.word] or 0]
        if style then
            for _, box in ipairs(w.boxes) do
                fill(bb, box, style)
            end
            if style.rgb then colorful = true end
        end
    end
    return colorful
end

--- Returns the word whose box contains the screen position, from the cached page.
function Overlay:wordAt(pos)
    local page = self:getCurrentCachedPage()
    if not page then return end
    for _, w in ipairs(page.words) do
        for _, box in ipairs(w.boxes) do
            if pos.x >= box.x and pos.x < box.x + box.w and pos.y >= box.y and pos.y < box.y + box.h then
                return w
            end
        end
    end
end

return Overlay

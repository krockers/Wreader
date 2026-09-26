--[[--
Background scan of a whole book for the Known words plugin.

Counts every word of the book once and stores the counts, so book stats
(unique words known, running text known) are cheap queries afterwards. The
scan runs in short slices scheduled on the UI loop, so reading is not blocked.

Text is read in chunks of pages. A chunk end is moved to the end of the word
it falls in, so words hyphenated across a page break are not split.

@module koplugin.knownwords.bookscan
--]]

local Tokenizer = require("tokenizer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")

local PAGES_PER_CHUNK = 8
local SLICE_BUDGET = time.ms(120) -- work per slice before yielding to the UI
local SLICE_DELAY = 0.05 -- seconds between slices
local MAX_LAST_PAGE_WORDS = 20000

local BookScan = {}
BookScan.__index = BookScan

--[[--
Creates a scan.

@tparam table o ui, on_done(counts, total) called when finished
--]]
function BookScan:new(o)
    o = setmetatable(o, self)
    o.step_func = function() o:step() end
    return o
end

function BookScan:start()
    local doc = self.ui.document
    self.render_hash = doc:getDocumentRenderingHash(false)
    self.page_count = doc:getPageCount()
    self.next_page = 1
    self.cursor = doc:getPageXPointer(1)
    self.counts, self.total = {}, 0
    self.started_at = time.monotonic()
    self.running = true
    UIManager:scheduleIn(1, self.step_func)
end

function BookScan:cancel()
    self.running = false
    UIManager:unschedule(self.step_func)
end

function BookScan:progress()
    if not self.page_count or self.page_count == 0 then return 0 end
    return math.min(1, (self.next_page - 1) / self.page_count)
end

function BookScan:add(text)
    if not text or text == "" then return end
    local _, n = Tokenizer.countWords(text, self.counts)
    self.total = self.total + n
end

-- Reads the remaining words from the cursor to the end of the document.
function BookScan:addLastPage()
    local doc = self.ui.document
    local parts = {}
    local ws = self.cursor
    -- The cursor is a word end (or the document start): the first word
    -- start after it is the next word.
    if self.next_page > 1 then
        ws = doc:getNextVisibleWordStart(ws)
    end
    local n = 0
    while ws and n < MAX_LAST_PAGE_WORDS do
        n = n + 1
        local we = doc:getNextVisibleWordEnd(ws)
        if not we then break end
        parts[#parts + 1] = doc:getTextFromXPointers(ws, we)
        ws = doc:getNextVisibleWordStart(we)
    end
    self:add(table.concat(parts, " "))
end

function BookScan:step()
    if not self.running then return end
    local doc = self.ui.document
    if doc:getDocumentRenderingHash(false) ~= self.render_hash then
        -- Layout changed (font size...): page xpointers are different now.
        logger.dbg("KnownWords: layout changed, restarting book scan")
        self:start()
        return
    end
    local deadline = time.monotonic() + SLICE_BUDGET
    local ok, err = pcall(function()
        while self.next_page < self.page_count and time.monotonic() < deadline do
            local last = math.min(self.next_page + PAGES_PER_CHUNK, self.page_count)
            local end_xp = doc:getPageXPointer(last)
            -- Extend to the end of the word the chunk end falls in (or
            -- starts): getNextVisibleWordEnd() from the character before.
            local prev_char = doc:getPrevVisibleChar(end_xp)
            local word_end = prev_char and doc:getNextVisibleWordEnd(prev_char)
            if word_end and doc:compareXPointers(self.cursor, word_end) == 1 then
                end_xp = word_end
            end
            self:add(doc:getTextFromXPointers(self.cursor, end_xp))
            self.cursor = end_xp
            self.next_page = last
        end
        if self.next_page >= self.page_count then
            self:addLastPage()
            self.next_page = self.page_count + 1
        end
    end)
    if not ok then
        logger.warn("KnownWords: book scan failed:", err)
        self.running = false
        return
    end
    if self.next_page > self.page_count then
        self.running = false
        logger.info("KnownWords: scanned", self.total, "words in",
            time.to_ms(time.monotonic() - self.started_at), "ms")
        self.on_done(self.counts, self.total)
        return
    end
    UIManager:scheduleIn(SLICE_DELAY, self.step_func)
end

return BookScan

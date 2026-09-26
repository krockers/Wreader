--[[--
Word splitting and normalization for the Known words plugin.

Splitting mirrors crengine's visible word rules (lvtinydom.cpp IsWordChar and
IsWordBoundary): a word is a run of letters, combining marks and digits, and
any punctuation, apostrophe, hyphen or space ends it. The page overlay gets its
words from crengine and the book scan gets them from this module, so both must
agree for the counts to match what is colored on the page.

This module is pure Lua so it can be unit tested without a device.

@module koplugin.knownwords.tokenizer
--]]

local Tokenizer = {
    -- Bump when splitting or normalization changes: cached book scans made
    -- with an older version are then redone.
    VERSION = 1,
}

local lowercase = string.lower

--- Sets the function used to lowercase words (Utf8Proc on the device).
function Tokenizer.setLowercase(fn)
    lowercase = fn
end

-- Decodes the UTF-8 character starting at byte i.
-- Returns the codepoint and the index of the next character.
local function decode(s, i)
    local c = s:byte(i)
    if c < 0x80 then
        return c, i + 1
    elseif c >= 0xF0 then
        local c2, c3, c4 = s:byte(i + 1, i + 3)
        if not c4 then return 0xFFFD, #s + 1 end
        return (c - 0xF0) * 0x40000 + (c2 - 0x80) * 0x1000 + (c3 - 0x80) * 0x40 + (c4 - 0x80), i + 4
    elseif c >= 0xE0 then
        local c2, c3 = s:byte(i + 1, i + 2)
        if not c3 then return 0xFFFD, #s + 1 end
        return (c - 0xE0) * 0x1000 + (c2 - 0x80) * 0x40 + (c3 - 0x80), i + 3
    elseif c >= 0xC0 then
        local c2 = s:byte(i + 1)
        if not c2 then return 0xFFFD, #s + 1 end
        return (c - 0xC0) * 0x40 + (c2 - 0x80), i + 2
    end
    -- Stray continuation byte: treat as a separator.
    return 0xFFFD, i + 1
end

local function isDigit(cp)
    return cp >= 0x30 and cp <= 0x39
end

--- Whether a codepoint can be part of a word.
function Tokenizer.isWordChar(cp)
    if cp < 0x80 then
        return isDigit(cp) or (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A)
    end
    if cp < 0xC0 then
        -- Latin-1 punctuation (¡ ¿ « » ...) separates words, except soft
        -- hyphen and the ordinal and micro signs.
        return cp == 0xAD or cp == 0xAA or cp == 0xB5 or cp == 0xBA
    end
    if cp == 0xD7 or cp == 0xF7 then return false end -- × ÷
    if cp <= 0x36F then return true end -- Latin letters, IPA, modifiers, combining marks
    if cp <= 0x3FF then return cp ~= 0x37E and cp ~= 0x387 end -- Greek, minus its punctuation
    if cp <= 0x52F then return true end -- Cyrillic
    if cp >= 0x1E00 and cp <= 0x1FFF then return true end -- Latin Extended Additional, Greek Extended
    if cp >= 0x2000 and cp <= 0x2BFF then return false end -- punctuation, symbols, arrows
    if cp >= 0x2E00 and cp <= 0x2E7F then return false end -- supplemental punctuation
    if cp >= 0x3000 and cp <= 0x303F then return false end -- CJK punctuation
    if cp >= 0xFE10 and cp <= 0xFE6F then return false end -- vertical and small forms
    if cp >= 0xFF00 and cp <= 0xFF20 then return false end -- fullwidth punctuation
    if cp == 0xFEFF or cp == 0xFFFD then return false end
    return true
end
local isWordChar = Tokenizer.isWordChar

--[[--
Iterates the words in a text.

@usage for word, start_byte in Tokenizer.words(text) do ... end
--]]
function Tokenizer.words(text)
    local i, n = 1, #text
    return function()
        -- skip separators
        local start
        while i <= n do
            local cp, next_i = decode(text, i)
            if isWordChar(cp) then
                start = i
                i = next_i
                break
            end
            i = next_i
        end
        if not start then return nil end
        while i <= n do
            local cp, next_i = decode(text, i)
            if not isWordChar(cp) then break end
            i = next_i
        end
        return text:sub(start, i - 1), start
    end
end

local SOFT_HYPHEN = "\194\173"

--[[--
Normalizes one word into the form words are stored under.

Soft hyphens are removed and the word is lowercased (Unicode case folding with
NFKC on the device, so "Ñ" and "ñ" match and composed and decomposed accents
match). Returns nil for words that contain no letter (numbers), which are
never tracked.
--]]
function Tokenizer.normalize(word)
    if not word or word == "" then return nil end
    word = word:gsub(SOFT_HYPHEN, "")
    local has_letter = false
    local i, n = 1, #word
    while i <= n do
        local cp, next_i = decode(word, i)
        if not isWordChar(cp) then return nil end
        if not isDigit(cp) then has_letter = true end
        i = next_i
    end
    if not has_letter then return nil end
    return lowercase(word)
end

--[[--
Normalizes the text crengine returns for one of its words.

crengine's word may carry punctuation at its edges in rare cases, so the text
is split again here. Returns nil unless it holds exactly one trackable word.
--]]
function Tokenizer.normalizeWord(text)
    if not text then return nil end
    local found
    for word in Tokenizer.words(text) do
        if found then return nil end
        found = word
    end
    return Tokenizer.normalize(found)
end

--[[--
Counts the trackable words of a text.

@treturn table counts, keyed by normalized word
@treturn int total number of trackable words (running words)
--]]
function Tokenizer.countWords(text, counts)
    counts = counts or {}
    local total = 0
    for word in Tokenizer.words(text) do
        local norm = Tokenizer.normalize(word)
        if norm then
            counts[norm] = (counts[norm] or 0) + 1
            total = total + 1
        end
    end
    return counts, total
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--[[--
Builds the sentence around a word from the text before and after it.

The text before is cut after its last sentence end and the text after is cut
at its first, so the result is roughly the sentence the word was met in.
--]]
function Tokenizer.sentence(prev, word, next)
    prev = (prev or ""):gsub("[\r\n]+", " ")
    next = (next or ""):gsub("[\r\n]+", " ")
    -- "…" is multibyte, so it cannot go in a Lua character class.
    local cut
    for pos in prev:gmatch("[%.!%?]%s+()") do cut = pos end
    for pos in prev:gmatch("…%s+()") do
        if not cut or pos > cut then cut = pos end
    end
    if cut then prev = prev:sub(cut) end
    local stop = next:find("[%.!%?]")
    local ellipsis = next:find("…", 1, true)
    if ellipsis and (not stop or ellipsis < stop) then
        stop = ellipsis + 2
    end
    if stop then next = next:sub(1, stop) end
    local s = trim(prev .. word .. next)
    if #s > 400 then
        local cut_at = 401
        -- don't cut inside a multibyte character
        while cut_at > 1 and s:byte(cut_at) >= 0x80 and s:byte(cut_at) < 0xC0 do
            cut_at = cut_at - 1
        end
        s = s:sub(1, cut_at - 1) .. "…"
    end
    return s
end

return Tokenizer

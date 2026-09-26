--[[--
Sentence translation view for the Known words plugin: pure helpers that mark
the looked-up word in the sentence and, when it can be found, its translation
in the translated sentence.

Finding the word in the translation is best effort: the word is translated on
its own too, and its translation (or an alternative) is searched for in the
translated sentence. Word order and inflection can change in translation, so
it is not always found.

@module koplugin.knownwords.translation
--]]

local Tokenizer = require("tokenizer")

local Translation = {}

-- Short words dropped from a candidate when the whole candidate is not found
-- ("the bench" is then searched for as "bench").
local FILLER = { the = true, a = true, an = true, to = true }

--[[--
Finds where a sequence of words occurs in a text.

@string text
@tparam table words array of normalized words
@treturn table array of { first_byte, last_byte }
--]]
function Translation.findWords(text, words)
    local ranges = {}
    if #words == 0 then return ranges end
    local tokens = {}
    for raw, start in Tokenizer.words(text) do
        tokens[#tokens + 1] = { norm = Tokenizer.normalize(raw), first = start, last = start + #raw - 1 }
    end
    local i = 1
    while i <= #tokens - #words + 1 do
        local match = true
        for k = 1, #words do
            if tokens[i + k - 1].norm ~= words[k] then
                match = false
                break
            end
        end
        if match then
            ranges[#ranges + 1] = { tokens[i].first, tokens[i + #words - 1].last }
            i = i + #words
        else
            i = i + 1
        end
    end
    return ranges
end

-- Normalized words of a text.
local function normalizedWords(text)
    local words = {}
    for raw in Tokenizer.words(text) do
        local norm = Tokenizer.normalize(raw)
        if norm then words[#words + 1] = norm end
    end
    return words
end

--[[--
Finds the first candidate translation of the word that occurs in the translated sentence.

@treturn table ranges (see findWords), empty if none is found
--]]
function Translation.findCandidate(text, candidates)
    for _, candidate in ipairs(candidates) do
        local ranges = Translation.findWords(text, normalizedWords(candidate))
        if #ranges > 0 then return ranges end
    end
    for _, candidate in ipairs(candidates) do
        local words = {}
        for _, w in ipairs(normalizedWords(candidate)) do
            if not FILLER[w] then words[#words + 1] = w end
        end
        local ranges = Translation.findWords(text, words)
        if #ranges > 0 then return ranges end
    end
    return {}
end

local function escape(text)
    return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end
Translation.escape = escape

--- Returns the text as HTML, with the byte ranges in bold and underlined.
function Translation.markHtml(text, ranges)
    local parts = {}
    local pos = 1
    for _, r in ipairs(ranges) do
        parts[#parts + 1] = escape(text:sub(pos, r[1] - 1))
        parts[#parts + 1] = "<b><u>" .. escape(text:sub(r[1], r[2])) .. "</u></b>"
        pos = r[2] + 1
    end
    parts[#parts + 1] = escape(text:sub(pos))
    return table.concat(parts)
end

--[[--
Returns the main translation from a translation service result (the JSON
array Translator:loadPage() returns), or nil.
--]]
function Translation.mainText(result)
    if type(result) ~= "table" or type(result[1]) ~= "table" then return nil end
    local parts = {}
    for _, slice in ipairs(result[1]) do
        if type(slice) == "table" and type(slice[1]) == "string" then
            parts[#parts + 1] = slice[1]
        end
    end
    local text = table.concat(parts)
    return text ~= "" and text or nil
end

--[[--
Returns the translations of a single word from a translation service result:
the main one first, then the alternatives (result[6], requested with dt=at).
--]]
function Translation.wordCandidates(result)
    local candidates, seen = {}, {}
    local function add(text)
        if type(text) == "string" and text ~= "" and not seen[text:lower()] then
            seen[text:lower()] = true
            candidates[#candidates + 1] = text
        end
    end
    add(Translation.mainText(result))
    local alternates = type(result) == "table" and result[6]
    if type(alternates) == "table" then
        for _, entry in ipairs(alternates) do
            if type(entry) == "table" and type(entry[3]) == "table" then
                for _, alt in ipairs(entry[3]) do
                    if type(alt) == "table" then add(alt[1]) end
                end
            end
        end
    end
    return candidates
end

--[[--
Builds the HTML of the translation view.

@string sentence the sentence being read
@string word the normalized word
@string raw the word as written in the sentence
@tparam table sentence_result translation service result for the sentence
@tparam[opt] table word_result translation service result for the word alone
@treturn string HTML, or nil if the sentence has no translation
--]]
function Translation.buildHtml(sentence, word, raw, sentence_result, word_result)
    local translated = Translation.mainText(sentence_result)
    if not translated then return nil end
    local candidates = Translation.wordCandidates(word_result)
    local html = {
        "<p>" .. Translation.markHtml(sentence, Translation.findWords(sentence, { word })) .. "</p>",
        "<p>" .. Translation.markHtml(translated, Translation.findCandidate(translated, candidates)) .. "</p>",
    }
    if #candidates > 0 then
        html[#html + 1] = "<p><i>" .. escape(raw) .. "</i>: " .. escape(table.concat(candidates, ", ", 1, math.min(#candidates, 5))) .. "</p>"
    end
    return table.concat(html, "\n")
end

return Translation

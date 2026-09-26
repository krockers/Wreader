--[[--
Grammar lookup for the Known words plugin.

Reads the grammar database built from Wiktionary data by
tools/knownwords_build_grammar.py: which base word(s) a word form belongs to,
the form's grammatical tags, the base word's part of speech, gender and gloss,
and its inflection table. Also turns that data into the HTML of the grammar
and conjugation views (pure functions, unit tested).

@module koplugin.knownwords.grammar
--]]

local SQ3 = require("lua-ljsqlite3/init")
local Translation = require("translation")
local _ = require("gettext")
local T = require("ffi/util").template

local escape = Translation.escape

local FORMAT_VERSION = "1"

local Grammar = {}
Grammar.__index = Grammar

--- Returns the path of the grammar database of a language.
function Grammar.path(settings_dir, lang)
    return settings_dir .. "/grammar_" .. lang .. ".sqlite3"
end

--[[--
Opens a grammar database read-only.

@treturn Grammar or nil, error message
--]]
function Grammar.open(path)
    local ok, conn = pcall(SQ3.open, path, "ro")
    if not ok then return nil, conn end
    local ok_meta, format = pcall(conn.rowexec, conn, "SELECT value FROM meta WHERE key = 'format';")
    if not ok_meta or format ~= FORMAT_VERSION then
        conn:close()
        return nil, "unsupported grammar database format: " .. tostring(format)
    end
    return setmetatable({ conn = conn, path = path }, Grammar)
end

function Grammar:close()
    if self.conn then
        self.conn:close()
        self.conn = nil
    end
end

function Grammar:query(sql, ...)
    local stmt = self.conn:prepare(sql)
    stmt:bind(...)
    local rows = {}
    local row = stmt:step()
    while row do
        rows[#rows + 1] = row
        row = stmt:step()
    end
    stmt:close()
    return rows
end

local function splitTags(text)
    local tags = {}
    for tag in (text or ""):gmatch("%S+") do tags[#tags + 1] = tag end
    return tags
end

--[[--
Looks up a normalized word.

@treturn table readings, one per base word: { lemma_id, word, pos, gender,
gloss, is_base (the word is this base word itself), forms = array of
{ form, tags (array), note } }
--]]
function Grammar:lookup(norm)
    local readings, by_id = {}, {}
    local function reading(row)
        local id = tonumber(row[1])
        if not by_id[id] then
            by_id[id] = { lemma_id = id, word = row[2], pos = row[3], gender = row[4], gloss = row[5], forms = {} }
            readings[#readings + 1] = by_id[id]
        end
        return by_id[id]
    end
    for _, row in ipairs(self:query("SELECT id, word, pos, gender, gloss FROM lemma WHERE norm = ? ORDER BY id;", norm)) do
        reading(row).is_base = true
    end
    for _, row in ipairs(self:query([[SELECT l.id, l.word, l.pos, l.gender, l.gloss, COALESCE(f.form, f.norm), t.tags, f.note
                                      FROM form f JOIN lemma l ON l.id = f.lemma_id JOIN tagset t ON t.id = f.tagset
                                      WHERE f.norm = ? ORDER BY l.id, f.in_table DESC;]], norm)) do
        local r = reading(row)
        table.insert(r.forms, { form = row[6], tags = splitTags(row[7]), note = row[8] })
    end
    return readings
end

--- Returns the inflection table rows of a base word: array of { form, tags }.
function Grammar:inflections(lemma_id)
    local forms = {}
    for _, row in ipairs(self:query([[SELECT COALESCE(f.form, f.norm), t.tags FROM form f JOIN tagset t ON t.id = f.tagset
                                      WHERE f.lemma_id = ? AND f.in_table = 1 ORDER BY f.rowid;]], lemma_id)) do
        forms[#forms + 1] = { form = row[1], tags = splitTags(row[2]) }
    end
    return forms
end

-- Descriptions -------------------------------------------------------------------

local function tagSet(tags)
    local set = {}
    for _, tag in ipairs(tags) do set[tag] = true end
    return set
end

-- Tags that describe nothing useful to a reader.
local SILENT = {
    ["informal"] = true, ["form-of"] = true, ["alt-of"] = true, ["second-person-semantically"] = true,
    ["formal"] = true, ["vos-form"] = true, ["imperfect-se"] = true, ["negative"] = true,
    ["accusative"] = true, ["dative"] = true, ["combined-form"] = true,
}

local POS_NAMES = {
    verb = _("verb"), noun = _("noun"), adj = _("adjective"), adv = _("adverb"), pron = _("pronoun"),
    det = _("determiner"), prep = _("preposition"), conj = _("conjunction"), intj = _("interjection"),
    num = _("numeral"), article = _("article"), name = _("name"), phrase = _("phrase"),
    contraction = _("contraction"), particle = _("particle"),
}

local GENDER_NAMES = {
    m = _("masculine"), f = _("feminine"), ["m/f"] = _("masculine or feminine"), n = _("neuter"),
}

function Grammar.posName(pos)
    return POS_NAMES[pos] or pos
end

function Grammar.genderName(gender)
    return GENDER_NAMES[gender] or gender
end

--[[--
Describes a form from its tags, e.g. "3rd person plural, preterite indicative".
--]]
function Grammar.describe(tags)
    local t = tagSet(tags)
    local parts = {}
    local function add(text) parts[#parts + 1] = text end

    if t.infinitive then add(_("infinitive")) end
    if t.gerund then add(_("gerund")) end
    if t.participle then add(t.past and _("past participle") or _("participle")) end

    -- who
    local who = {}
    if t.formal and t["second-person-semantically"] then
        who[#who + 1] = t.plural and "ustedes" or "usted"
    else
        if t["first-person"] then who[#who + 1] = _("1st person") end
        if t["second-person"] then who[#who + 1] = _("2nd person") end
        if t["third-person"] then who[#who + 1] = _("3rd person") end
        if t.singular then who[#who + 1] = _("singular") end
        if t.plural then who[#who + 1] = _("plural") end
        if t["vos-form"] then who[#who + 1] = _("(vos)") end
    end
    if t.neuter then table.insert(who, 1, _("neuter")) end
    if t.feminine then table.insert(who, 1, _("feminine")) end
    if t.masculine then table.insert(who, 1, _("masculine")) end
    if #who > 0 then add(table.concat(who, " ")) end

    -- when and how
    local when = {}
    if t.present then when[#when + 1] = _("present") end
    if t.imperfect then when[#when + 1] = t["imperfect-se"] and _("imperfect (-se)") or _("imperfect") end
    if t.preterite then when[#when + 1] = _("preterite") end
    if t.future then when[#when + 1] = _("future") end
    if t.conditional then when[#when + 1] = _("conditional") end
    if t.indicative and not t.conditional then when[#when + 1] = _("indicative") end
    if t.subjunctive then when[#when + 1] = _("subjunctive") end
    if t.imperative then when[#when + 1] = t.negative and _("negative imperative") or _("imperative") end
    if #when > 0 then add(table.concat(when, " ")) end

    if t["combined-form"] then
        local object = {}
        if t["object-first-person"] then object[#object + 1] = _("1st person") end
        if t["object-second-person"] then object[#object + 1] = _("2nd person") end
        if t["object-third-person"] then object[#object + 1] = _("3rd person") end
        if t["object-singular"] then object[#object + 1] = _("singular") end
        if t["object-plural"] then object[#object + 1] = _("plural") end
        add(T(_("with attached pronoun (%1)"), table.concat(object, " ")))
    end

    -- anything else (diminutive, alternative, augmentative...), as written
    local known = {
        infinitive = true, gerund = true, participle = true, past = true, singular = true, plural = true,
        ["first-person"] = true, ["second-person"] = true, ["third-person"] = true,
        masculine = true, feminine = true, neuter = true, present = true, imperfect = true,
        preterite = true, future = true, conditional = true, indicative = true, subjunctive = true,
        imperative = true,
    }
    for _, tag in ipairs(tags) do
        if not known[tag] and not SILENT[tag] and not tag:match("^object%-") and not tag:match("^with%-") then
            add((tag:gsub("%-", " ")))
        end
    end
    return table.concat(parts, ", ")
end

-- Conjugation table ------------------------------------------------------------------

-- Person of a verb form in the conjugation table, or nil. The formal "usted"
-- rows repeat the 3rd person forms, so they are left out.
function Grammar.person(tags)
    local t = tagSet(tags)
    if t["combined-form"] or (t.formal and t["second-person-semantically"]) then return nil end
    if t["first-person"] then return t.plural and "nosotros" or "yo" end
    if t["second-person"] then
        if t.plural then return "vosotros" end
        return t["vos-form"] and "vos" or "tu"
    end
    if t["third-person"] then return t.plural and "ellos" or "el" end
end

local PERSONS = {
    { "yo", "yo" }, { "tu", "tú" }, { "vos", "vos" }, { "el", "él/ella/usted" },
    { "nosotros", "nosotros" }, { "vosotros", "vosotros" }, { "ellos", "ellos/ellas/ustedes" },
}

-- Rows of the table: label, tags a form must have, tags it must not have.
local SECTIONS = {
    { _("Indicative"), {
        { _("Present"), { "indicative", "present" } },
        { _("Imperfect"), { "indicative", "imperfect" } },
        { _("Preterite"), { "indicative", "preterite" } },
        { _("Future"), { "indicative", "future" } },
        { _("Conditional"), { "conditional" } },
    } },
    { _("Subjunctive"), {
        { _("Present"), { "subjunctive", "present" } },
        { _("Imperfect (-ra)"), { "subjunctive", "imperfect" }, { "imperfect-se" } },
        { _("Imperfect (-se)"), { "subjunctive", "imperfect-se" } },
        { _("Future"), { "subjunctive", "future" } },
    } },
    { _("Imperative"), {
        { _("Affirmative"), { "imperative" }, { "negative" } },
        { _("Negative"), { "imperative", "negative" } },
    } },
}

local function matches(set, required, excluded)
    for _, tag in ipairs(required) do
        if not set[tag] then return false end
    end
    for _, tag in ipairs(excluded or {}) do
        if set[tag] then return false end
    end
    return true
end

--[[--
Builds the HTML of a verb's conjugation table.

@string word the base word
@tparam table forms its inflections (see Grammar:inflections)
@treturn string HTML, or nil if there are no conjugated forms
--]]
function Grammar.conjugationHtml(word, forms)
    local html = {}
    local nonfinite = {}
    -- (translated before the loops: their "_" variable hides gettext)
    local gerund_text, participle_text = _("gerund: %1"), _("past participle: %1")
    for _, f in ipairs(forms) do
        local t = tagSet(f.tags)
        if not t["combined-form"] then
            if t.gerund then
                nonfinite[#nonfinite + 1] = T(gerund_text, escape(f.form))
            elseif t.participle and t.masculine and t.singular then
                nonfinite[#nonfinite + 1] = T(participle_text, escape(f.form))
            end
        end
    end
    if #nonfinite > 0 then
        html[#html + 1] = "<p>" .. table.concat(nonfinite, " · ") .. "</p>"
    end
    local found = false
    for _, section in ipairs(SECTIONS) do
        local rows = {}
        for _, spec in ipairs(section[2]) do
            local by_person = {}
            for _, f in ipairs(forms) do
                local set = tagSet(f.tags)
                local person = Grammar.person(f.tags)
                if person and matches(set, spec[2], spec[3]) then
                    by_person[person] = by_person[person] or {}
                    table.insert(by_person[person], escape(f.form))
                end
            end
            local cells = {}
            for _, p in ipairs(PERSONS) do
                if by_person[p[1]] then
                    cells[#cells + 1] = "<i>" .. p[2] .. "</i> " .. table.concat(by_person[p[1]], ", ")
                end
            end
            if #cells > 0 then
                rows[#rows + 1] = "<b>" .. spec[1] .. "</b><br/>" .. table.concat(cells, " · ")
            end
        end
        if #rows > 0 then
            found = true
            html[#html + 1] = "<h3>" .. section[1] .. "</h3>"
            html[#html + 1] = "<p>" .. table.concat(rows, "</p>\n<p>") .. "</p>"
        end
    end
    if not found then return nil end
    return table.concat(html, "\n")
end

-- Grammar view --------------------------------------------------------------------------

local ATTRIBUTION = _("Grammar data: Wiktionary, CC BY-SA.")

--[[--
Builds the HTML of the grammar view of a word.

@string word the word as tapped
@tparam table readings see Grammar:lookup; each may carry inflections (array
of { form, tags }) for nouns and adjectives
--]]
function Grammar.readingsHtml(word, readings)
    local html = {}
    -- (translated before the loops: their "_" variable hides gettext)
    local base_form_text, forms_text = _("base form"), _("Forms: %1")
    for _, r in ipairs(readings) do
        local head = "<b>" .. escape(r.word) .. "</b> · " .. escape(Grammar.posName(r.pos))
        if r.gender then head = head .. ", " .. escape(Grammar.genderName(r.gender)) end
        local lines = { head }
        if r.is_base and #r.forms == 0 then
            lines[#lines + 1] = base_form_text
        end
        local seen = {}
        for _, f in ipairs(r.forms) do
            local text = Grammar.describe(f.tags)
            if text == "" then text = f.note or "" end
            if f.form and f.form:find(" ") then
                text = text .. " (" .. f.form .. ")" -- "me lavo": the full reflexive form
            end
            if text ~= "" and not seen[text] then
                seen[text] = true
                lines[#lines + 1] = escape(text)
            end
        end
        if r.inflections and #r.inflections > 0 then
            local parts = {}
            for _, f in ipairs(r.inflections) do
                parts[#parts + 1] = escape(f.form) .. " <i>(" .. escape(Grammar.describe(f.tags)) .. ")</i>"
            end
            lines[#lines + 1] = T(forms_text, table.concat(parts, ", "))
        end
        if r.gloss then
            lines[#lines + 1] = "<i>" .. escape(r.gloss) .. "</i>"
        end
        html[#html + 1] = "<p>" .. table.concat(lines, "<br/>") .. "</p>"
    end
    html[#html + 1] = "<p><small>" .. ATTRIBUTION .. "</small></p>"
    return table.concat(html, "\n")
end

return Grammar

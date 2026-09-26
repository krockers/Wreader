--[[--
Word states and their default display for the Known words plugin.

A word with no stored row is new. Stored states are integers so that the
database, the CSV files and the code agree.

@module koplugin.knownwords.states
--]]

local _ = require("gettext")

local States = {
    NEW = 0,
    LEVEL1 = 1,
    LEVEL2 = 2,
    LEVEL3 = 3,
    KNOWN = 4,
    IGNORED = 5,
}

-- Display order in the word panel and the vocabulary list.
States.ORDER = { 0, 1, 2, 3, 4, 5 }

States.NAMES = {
    [0] = _("New"),
    [1] = _("Level 1"),
    [2] = _("Level 2"),
    [3] = _("Level 3"),
    [4] = _("Known"),
    [5] = _("Ignored"),
}

-- Short labels for button rows.
States.SHORT = {
    [0] = _("New"),
    [1] = "1",
    [2] = "2",
    [3] = "3",
    [4] = _("Known"),
    [5] = _("Ignore"),
}

-- Names used in CSV files, so exports stay readable whatever the UI language.
States.CSV_NAMES = {
    [0] = "new",
    [1] = "1",
    [2] = "2",
    [3] = "3",
    [4] = "known",
    [5] = "ignored",
}

-- Default fill colors, as keys of Blitbuffer.HIGHLIGHT_COLORS. Only states
-- that are colored on the page have one.
States.DEFAULT_COLORS = {
    [0] = "blue",
    [1] = "red",
    [2] = "orange",
    [3] = "green",
}

-- Darkening used instead of colors on grayscale screens (or with color
-- rendering off). New words are underlined instead, see overlay.lua.
States.GRAY_DARKEN = {
    [1] = 0.40,
    [2] = 0.28,
    [3] = 0.16,
}

function States.isLearning(state)
    return state == 1 or state == 2 or state == 3
end

--- Whether the state is shown on the page (new and learning words).
function States.isColored(state)
    return state == 0 or States.isLearning(state)
end

--- Parses a state from a CSV value: a number or a CSV name. Returns nil if unknown.
function States.parse(value)
    if value == nil then return nil end
    value = tostring(value):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local n = tonumber(value)
    if n and States.NAMES[n] then return n end
    for state, name in pairs(States.CSV_NAMES) do
        if name == value then return state end
    end
    if value == "ignore" then return States.IGNORED end
    if value == "learning" then return States.LEVEL1 end
    return nil
end

return States

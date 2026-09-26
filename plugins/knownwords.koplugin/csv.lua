--[[--
Minimal CSV reading and writing (RFC 4180 quoting) for word import and export.

@module koplugin.knownwords.csv
--]]

local Csv = {}

local function quote(value)
    if value == nil then return "" end
    value = tostring(value)
    if value:find('[,"\r\n]') then
        return '"' .. value:gsub('"', '""') .. '"'
    end
    return value
end

--- Formats one row (an array of values) as a CSV line, without line ending.
function Csv.formatRow(row, ncols)
    local out = {}
    for i = 1, ncols or #row do
        out[i] = quote(row[i])
    end
    return table.concat(out, ",")
end

--[[--
Parses CSV text into an array of rows, each an array of strings.

Handles quoted fields with commas, doubled quotes and line breaks, CRLF line
endings, a UTF-8 byte order mark, and skips empty lines.
--]]
function Csv.parse(text)
    if text:sub(1, 3) == "\239\187\191" then
        text = text:sub(4)
    end
    local rows = {}
    local row, field = {}, {}
    local i, n = 1, #text
    local in_quotes = false
    local function endField()
        row[#row + 1] = table.concat(field)
        field = {}
    end
    local function endRow()
        endField()
        if not (#row == 1 and row[1] == "") then
            rows[#rows + 1] = row
        end
        row = {}
    end
    while i <= n do
        local c = text:sub(i, i)
        if in_quotes then
            if c == '"' then
                if text:sub(i + 1, i + 1) == '"' then
                    field[#field + 1] = '"'
                    i = i + 1
                else
                    in_quotes = false
                end
            else
                field[#field + 1] = c
            end
        elseif c == '"' then
            in_quotes = true
        elseif c == "," then
            endField()
        elseif c == "\n" then
            endRow()
        elseif c == "\r" then
            if text:sub(i + 1, i + 1) == "\n" then i = i + 1 end
            endRow()
        else
            field[#field + 1] = c
        end
        i = i + 1
    end
    if #field > 0 or #row > 0 then
        endRow()
    end
    return rows
end

return Csv

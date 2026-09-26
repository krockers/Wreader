--[[--
SQLite storage for the Known words plugin.

One database holds every tracked word with its state, meaning and notes, an
append-only log of events (lookups and state changes), daily reading counts,
and the cached word counts of scanned books.

A Store keeps its connection open; the plugin opens one per opened book and
closes it with the book.

@module koplugin.knownwords.store
--]]

local SQ3 = require("lua-ljsqlite3/init")
local States = require("states")

local SCHEMA_VERSION = 1

local SCHEMA = [[
    CREATE TABLE IF NOT EXISTS word (
        lang        TEXT NOT NULL,
        word        TEXT NOT NULL,
        state       INTEGER NOT NULL DEFAULT 0,
        meaning     TEXT,
        notes       TEXT,
        context     TEXT,
        book_title  TEXT,
        lookups     INTEGER NOT NULL DEFAULT 0,
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL,
        known_at    INTEGER,
        PRIMARY KEY (lang, word)
    );
    CREATE INDEX IF NOT EXISTS word_state_index ON word (lang, state);
    CREATE INDEX IF NOT EXISTS word_known_at_index ON word (lang, known_at);
    CREATE TABLE IF NOT EXISTS event (
        id          INTEGER PRIMARY KEY,
        lang        TEXT NOT NULL,
        word        TEXT NOT NULL,
        kind        TEXT NOT NULL,
        from_state  INTEGER,
        to_state    INTEGER,
        book_md5    TEXT,
        at          INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS event_at_index ON event (lang, kind, at);
    CREATE TABLE IF NOT EXISTS daily (
        lang        TEXT NOT NULL,
        day         TEXT NOT NULL,
        words_read  INTEGER NOT NULL DEFAULT 0,
        pages_read  INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (lang, day)
    );
    CREATE TABLE IF NOT EXISTS book (
        md5         TEXT PRIMARY KEY,
        title       TEXT,
        lang        TEXT NOT NULL,
        total_words INTEGER NOT NULL,
        unique_words INTEGER NOT NULL,
        tokenizer_version INTEGER NOT NULL,
        scanned_at  INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS book_word (
        md5         TEXT NOT NULL,
        word        TEXT NOT NULL,
        count       INTEGER NOT NULL,
        PRIMARY KEY (md5, word)
    );
]]

local Store = {}
Store.__index = Store

local function num(v)
    return v ~= nil and tonumber(v) or nil
end

local function today(now)
    return os.date("%Y-%m-%d", now or os.time())
end
Store.today = today

--[[--
Opens (and creates or migrates) the database.

@string path database file
@bool use_wal use write-ahead logging (Device:canUseWAL())
--]]
function Store.open(path, use_wal)
    local conn = SQ3.open(path)
    conn:exec(use_wal and "PRAGMA journal_mode=WAL;" or "PRAGMA journal_mode=TRUNCATE;")
    conn:exec(SCHEMA)
    local version = tonumber(conn:rowexec("PRAGMA user_version;"))
    if version < SCHEMA_VERSION then
        -- Future migrations go here, keyed on version.
        conn:exec(string.format("PRAGMA user_version=%d;", SCHEMA_VERSION))
    end
    return setmetatable({ conn = conn, path = path }, Store)
end

function Store:close()
    if self.conn then
        self.conn:close()
        self.conn = nil
    end
end

-- Runs fn inside a transaction, rolling back if it errors.
function Store:transaction(fn)
    self.conn:exec("BEGIN;")
    local ok, res = pcall(fn)
    if ok then
        self.conn:exec("COMMIT;")
        return res
    end
    self.conn:exec("ROLLBACK;")
    error(res, 0)
end

-- Runs a query with bound values and returns all rows as arrays.
function Store:query(sql, ...)
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

-- Runs a statement with bound values.
function Store:run(sql, ...)
    local stmt = self.conn:prepare(sql)
    stmt:bind(...)
    stmt:step()
    stmt:close()
end

--- Returns a table mapping each word with a state other than new to its state.
function Store:loadStates(lang)
    local states = {}
    for _, row in ipairs(self:query("SELECT word, state FROM word WHERE lang = ? AND state <> 0;", lang)) do
        states[row[1]] = tonumber(row[2])
    end
    return states
end

function Store:getState(lang, word)
    local rows = self:query("SELECT state FROM word WHERE lang = ? AND word = ?;", lang, word)
    return rows[1] and tonumber(rows[1][1]) or States.NEW
end

--- Returns the stored row for a word, or nil if it has none.
function Store:getWord(lang, word)
    local row = self:query([[SELECT word, state, meaning, notes, context, book_title, lookups,
                                    created_at, updated_at, known_at
                             FROM word WHERE lang = ? AND word = ?;]], lang, word)[1]
    if not row then return nil end
    return {
        word = row[1],
        state = tonumber(row[2]),
        meaning = row[3],
        notes = row[4],
        context = row[5],
        book_title = row[6],
        lookups = tonumber(row[7]),
        created_at = num(row[8]),
        updated_at = num(row[9]),
        known_at = num(row[10]),
    }
end

function Store:logEvent(lang, word, kind, from_state, to_state, book_md5, at)
    self:run([[INSERT INTO event (lang, word, kind, from_state, to_state, book_md5, at)
               VALUES (?, ?, ?, ?, ?, ?, ?);]],
             lang, word, kind, from_state, to_state, book_md5, at or os.time())
end

-- Writes a state change without logging it. info: book_title, context, now.
function Store:_writeState(lang, word, state, info)
    local now = info.now or os.time()
    local known_at = state == States.KNOWN and now or nil
    self:run([[INSERT INTO word (lang, word, state, context, book_title, created_at, updated_at, known_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT (lang, word) DO UPDATE SET
                   state = excluded.state,
                   updated_at = excluded.updated_at,
                   known_at = excluded.known_at,
                   context = COALESCE(word.context, excluded.context),
                   book_title = COALESCE(word.book_title, excluded.book_title);]],
             lang, word, state, info.context, info.book_title, now, now, known_at)
end

--[[--
Sets the state of one word.

@tparam table info optional: kind (event kind, default "state"), book_md5,
book_title, context (the sentence, kept only if the word has none yet), now
@treturn int the previous state
--]]
function Store:setState(lang, word, state, info)
    info = info or {}
    local old = self:getState(lang, word)
    if old == state then return old end
    self:transaction(function()
        self:_writeState(lang, word, state, info)
        self:logEvent(lang, word, info.kind or "state", old, state, info.book_md5, info.now)
    end)
    return old
end

--[[--
Sets the state of several words at once, in one transaction.

@tparam table words array of normalized words
@tparam table info as for setState, plus only_from: if set, only words
currently in that state are changed
@treturn table the words that changed
--]]
function Store:setStates(lang, words, state, info)
    info = info or {}
    local changed = {}
    self:transaction(function()
        local seen = {}
        for _, word in ipairs(words) do
            if not seen[word] then
                seen[word] = true
                local old = self:getState(lang, word)
                if old ~= state and (info.only_from == nil or old == info.only_from) then
                    self:_writeState(lang, word, state, info)
                    self:logEvent(lang, word, info.kind or "state", old, state, info.book_md5, info.now)
                    changed[#changed + 1] = word
                end
            end
        end
    end)
    return changed
end

--- Records a dictionary lookup of a word (creating its row if needed).
function Store:logLookup(lang, word, info)
    info = info or {}
    local now = info.now or os.time()
    self:transaction(function()
        self:run([[INSERT INTO word (lang, word, state, context, book_title, lookups, created_at, updated_at)
                   VALUES (?, ?, 0, ?, ?, 1, ?, ?)
                   ON CONFLICT (lang, word) DO UPDATE SET
                       lookups = word.lookups + 1,
                       context = COALESCE(word.context, excluded.context),
                       book_title = COALESCE(word.book_title, excluded.book_title);]],
                 lang, word, info.context, info.book_title, now, now)
        self:logEvent(lang, word, "lookup", nil, nil, info.book_md5, now)
    end)
end

-- Sets a text field (meaning or notes) of a word, creating its row if needed.
function Store:_setField(lang, word, field, value)
    if value == "" then value = nil end
    local now = os.time()
    self:run(string.format([[INSERT INTO word (lang, word, state, %s, created_at, updated_at)
                             VALUES (?, ?, 0, ?, ?, ?)
                             ON CONFLICT (lang, word) DO UPDATE SET
                                 %s = excluded.%s, updated_at = excluded.updated_at;]], field, field, field),
             lang, word, value, now, now)
end

function Store:setMeaning(lang, word, meaning)
    self:_setField(lang, word, "meaning", meaning)
end

function Store:setNotes(lang, word, notes)
    self:_setField(lang, word, "notes", notes)
end

--- Adds read words and pages to today's counts.
function Store:addRead(lang, words, pages, now)
    self:run([[INSERT INTO daily (lang, day, words_read, pages_read) VALUES (?, ?, ?, ?)
               ON CONFLICT (lang, day) DO UPDATE SET
                   words_read = daily.words_read + excluded.words_read,
                   pages_read = daily.pages_read + excluded.pages_read;]],
             lang, today(now), words, pages)
end

-- Book scans ------------------------------------------------------------------

--- Returns the cached scan of a book, or nil.
function Store:getBook(md5)
    local row = self:query([[SELECT md5, title, lang, total_words, unique_words, tokenizer_version, scanned_at
                             FROM book WHERE md5 = ?;]], md5)[1]
    if not row then return nil end
    return {
        md5 = row[1],
        title = row[2],
        lang = row[3],
        total_words = tonumber(row[4]),
        unique_words = tonumber(row[5]),
        tokenizer_version = tonumber(row[6]),
        scanned_at = num(row[7]),
    }
end

--[[--
Saves the word counts of a scanned book, replacing any previous scan.

@tparam table counts word counts keyed by normalized word
@int total number of running words
--]]
function Store:saveBookScan(md5, title, lang, counts, total, tokenizer_version)
    self:transaction(function()
        self:run("DELETE FROM book_word WHERE md5 = ?;", md5)
        local stmt = self.conn:prepare("INSERT INTO book_word (md5, word, count) VALUES (?, ?, ?);")
        local unique = 0
        for word, count in pairs(counts) do
            stmt:bind(md5, word, count)
            stmt:step()
            stmt:clearbind():reset()
            unique = unique + 1
        end
        stmt:close()
        self:run([[INSERT OR REPLACE INTO book (md5, title, lang, total_words, unique_words, tokenizer_version, scanned_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?);]],
                 md5, title, lang, total, unique, tokenizer_version, os.time())
    end)
end

--[[--
Summarizes per-state counts into the figures shown in stats.

Ignored words are left out of every percentage.

@tparam table by_state { [state] = { unique = n, running = n } }
--]]
function Store.summarize(by_state)
    local s = {
        unique = 0, running = 0,
        known_unique = 0, known_running = 0,
        learning_unique = 0, learning_running = 0,
        new_unique = 0, new_running = 0,
        ignored_unique = 0, ignored_running = 0,
    }
    for state, c in pairs(by_state) do
        s.unique = s.unique + c.unique
        s.running = s.running + c.running
        if state == States.KNOWN then
            s.known_unique, s.known_running = c.unique, c.running
        elseif state == States.IGNORED then
            s.ignored_unique, s.ignored_running = c.unique, c.running
        elseif States.isLearning(state) then
            s.learning_unique = s.learning_unique + c.unique
            s.learning_running = s.learning_running + c.running
        else
            s.new_unique, s.new_running = c.unique, c.running
        end
    end
    local unique_base = s.unique - s.ignored_unique
    local running_base = s.running - s.ignored_running
    s.known_unique_pct = unique_base > 0 and 100 * s.known_unique / unique_base or 0
    s.known_running_pct = running_base > 0 and 100 * s.known_running / running_base or 0
    s.learning_unique_pct = unique_base > 0 and 100 * s.learning_unique / unique_base or 0
    s.new_unique_pct = unique_base > 0 and 100 * s.new_unique / unique_base or 0
    return s
end

--- Returns the summarized stats of a scanned book (see summarize), or nil.
function Store:bookStats(md5, lang)
    local rows = self:query([[SELECT COALESCE(w.state, 0), COUNT(*), SUM(bw.count)
                              FROM book_word bw
                              LEFT JOIN word w ON w.lang = ? AND w.word = bw.word
                              WHERE bw.md5 = ?
                              GROUP BY COALESCE(w.state, 0);]], lang, md5)
    if #rows == 0 then return nil end
    local by_state = {}
    for _, row in ipairs(rows) do
        by_state[tonumber(row[1])] = { unique = tonumber(row[2]), running = tonumber(row[3]) }
    end
    return Store.summarize(by_state)
end

--- Returns the number of stored words per state (new words only if they have a row).
function Store:stateCounts(lang)
    local counts = {}
    for _, state in ipairs(States.ORDER) do counts[state] = 0 end
    for _, row in ipairs(self:query("SELECT state, COUNT(*) FROM word WHERE lang = ? GROUP BY state;", lang)) do
        counts[tonumber(row[1])] = tonumber(row[2])
    end
    return counts
end

--[[--
Returns reading activity for the last days, oldest first.

Each day: day, words_read, pages_read, lookups, new_known (words that became
known that day and still are), known_total (known words at the end of that day).
--]]
function Store:activity(lang, days, now)
    now = now or os.time()
    local first_day = today(now - (days - 1) * 86400)
    local by_day = {}
    local list = {}
    for i = days - 1, 0, -1 do
        local d = today(now - i * 86400)
        if not by_day[d] then
            by_day[d] = { day = d, words_read = 0, pages_read = 0, lookups = 0, new_known = 0 }
            list[#list + 1] = by_day[d]
        end
    end
    for _, row in ipairs(self:query("SELECT day, words_read, pages_read FROM daily WHERE lang = ? AND day >= ?;",
                                    lang, first_day)) do
        local d = by_day[row[1]]
        if d then
            d.words_read, d.pages_read = tonumber(row[2]), tonumber(row[3])
        end
    end
    for _, row in ipairs(self:query([[SELECT date(at, 'unixepoch', 'localtime'), COUNT(*) FROM event
                                      WHERE lang = ? AND kind = 'lookup' AND date(at, 'unixepoch', 'localtime') >= ?
                                      GROUP BY 1;]], lang, first_day)) do
        local d = by_day[row[1]]
        if d then d.lookups = tonumber(row[2]) end
    end
    for _, row in ipairs(self:query([[SELECT date(known_at, 'unixepoch', 'localtime'), COUNT(*) FROM word
                                      WHERE lang = ? AND state = 4 AND known_at IS NOT NULL
                                      AND date(known_at, 'unixepoch', 'localtime') >= ?
                                      GROUP BY 1;]], lang, first_day)) do
        local d = by_day[row[1]]
        if d then d.new_known = tonumber(row[2]) end
    end
    -- Known words before the first day, then accumulate.
    local total = tonumber(self:query([[SELECT COUNT(*) FROM word WHERE lang = ? AND state = 4
                                        AND (known_at IS NULL OR date(known_at, 'unixepoch', 'localtime') < ?);]],
                                      lang, first_day)[1][1])
    for _, d in ipairs(list) do
        total = total + d.new_known
        d.known_total = total
    end
    return list
end

--[[--
Lists stored words.

@tparam table opts state (only this state), search (substring), order
("word" or "recent", default "word")
@treturn table array of { word, state, meaning }
--]]
function Store:listWords(lang, opts)
    opts = opts or {}
    local where, args = { "lang = ?" }, { lang }
    if opts.state then
        where[#where + 1] = "state = ?"
        args[#args + 1] = opts.state
    else
        -- New words only have a row because of a lookup or a meaning.
        where[#where + 1] = "(state <> 0 OR meaning IS NOT NULL OR notes IS NOT NULL OR lookups > 0)"
    end
    if opts.search and opts.search ~= "" then
        where[#where + 1] = "word LIKE ? ESCAPE '\\'"
        args[#args + 1] = "%" .. opts.search:gsub("[%%_\\]", "\\%0") .. "%"
    end
    local order = opts.order == "recent" and "updated_at DESC" or "word COLLATE NOCASE"
    local sql = "SELECT word, state, meaning FROM word WHERE " .. table.concat(where, " AND ")
        .. " ORDER BY " .. order .. ";"
    local list = {}
    for _, row in ipairs(self:query(sql, unpack(args))) do
        list[#list + 1] = { word = row[1], state = tonumber(row[2]), meaning = row[3] }
    end
    return list
end

--- Deletes every word, event and daily count of a language (book scans are kept).
function Store:deleteLanguage(lang)
    self:transaction(function()
        self:run("DELETE FROM word WHERE lang = ?;", lang)
        self:run("DELETE FROM event WHERE lang = ?;", lang)
        self:run("DELETE FROM daily WHERE lang = ?;", lang)
    end)
end

-- Import and export -------------------------------------------------------------

Store.EXPORT_HEADER = { "word", "state", "meaning", "notes", "context", "book", "created", "known" }

--- Returns all stored words of a language as CSV rows (header first).
function Store:exportRows(lang)
    local rows = { Store.EXPORT_HEADER }
    for _, row in ipairs(self:query([[SELECT word, state, meaning, notes, context, book_title, created_at, known_at
                                      FROM word WHERE lang = ? ORDER BY word;]], lang)) do
        local created, known = num(row[7]), num(row[8])
        rows[#rows + 1] = {
            row[1],
            States.CSV_NAMES[tonumber(row[2])],
            row[3], row[4], row[5], row[6],
            created and os.date("%Y-%m-%d", created) or nil,
            known and os.date("%Y-%m-%d", known) or nil,
        }
    end
    return rows
end

--[[--
Imports words from CSV rows.

The first column is the word, the second its state (a number 0-5 or new,
known, ignored; missing means known), the third an optional meaning. A header
row starting with "word" is skipped. Existing meanings are not overwritten by
empty ones.

@func normalize normalizes a word; rows whose word it rejects are skipped
@treturn table counts: added, updated, unchanged, skipped
--]]
function Store:importRows(lang, rows, normalize, now)
    now = now or os.time()
    local result = { added = 0, updated = 0, unchanged = 0, skipped = 0 }
    self:transaction(function()
        for i, row in ipairs(rows) do
            local raw = row[1]
            local is_header = i == 1 and raw ~= nil and raw:lower() == "word"
            if not is_header then
                local word = raw and normalize(raw)
                local state
                if row[2] == nil or row[2] == "" then
                    state = States.KNOWN
                else
                    state = States.parse(row[2])
                end
                if not word or not state then
                    result.skipped = result.skipped + 1
                else
                    local existing = self:getWord(lang, word)
                    local meaning = row[3] ~= "" and row[3] or nil
                    if not existing then
                        result.added = result.added + 1
                    elseif existing.state == state and (not meaning or meaning == existing.meaning) then
                        result.unchanged = result.unchanged + 1
                    else
                        result.updated = result.updated + 1
                    end
                    if not existing or existing.state ~= state then
                        self:_writeState(lang, word, state, { now = now })
                        self:logEvent(lang, word, "import", existing and existing.state or States.NEW, state, nil, now)
                    end
                    if meaning and (not existing or meaning ~= existing.meaning) then
                        self:_setField(lang, word, "meaning", meaning)
                    end
                end
            end
        end
    end)
    return result
end

return Store

describe("Known words plugin", function()
    local Tokenizer, States, Csv, Store, Overlay, BookScan, Translation

    setup(function()
        require("commonrequire")
        package.path = "plugins/knownwords.koplugin/?.lua;" .. package.path
        Tokenizer = require("tokenizer")
        States = require("states")
        Csv = require("csv")
        Store = require("store")
        Overlay = require("overlay")
        BookScan = require("bookscan")
        Translation = require("translation")
    end)

    local function collectWords(text)
        local out = {}
        for word in Tokenizer.words(text) do out[#out + 1] = word end
        return out
    end

    describe("tokenizer", function()
        it("splits on spaces and Spanish punctuation", function()
            assert.are.same({ "Qué", "tal", "dijo", "María", "Sí" },
                collectWords("¿Qué tal? —dijo María—. «¡Sí!»"))
        end)

        it("splits on apostrophes and hyphens like crengine", function()
            assert.are.same({ "l", "homme", "niño", "a" }, collectWords("l'homme niño-a"))
        end)

        it("drops soft hyphens and lowercases", function()
            assert.are.equal("palabra", Tokenizer.normalize("Pala\194\173bra"))
            assert.are.equal("casa", Tokenizer.normalize("CASA"))
        end)

        it("does not track numbers", function()
            assert.is_nil(Tokenizer.normalize("1984"))
            assert.are.equal("s2", Tokenizer.normalize("s2"))
        end)

        it("normalizes a crengine word only when it is one word", function()
            assert.are.equal("hola", Tokenizer.normalizeWord("¡Hola!"))
            assert.is_nil(Tokenizer.normalizeWord("sí-no"))
            assert.is_nil(Tokenizer.normalizeWord("—"))
            assert.is_nil(Tokenizer.normalizeWord(nil))
        end)

        it("counts words", function()
            local counts, total = Tokenizer.countWords("El perro y el gato. EL fin, 2024.")
            assert.are.equal(7, total)
            assert.are.equal(3, counts.el)
            assert.is_nil(counts["2024"])
        end)

        it("extracts the sentence around a word", function()
            assert.are.equal("Luego vino el perro grande.",
                Tokenizer.sentence("Primero. Luego vino el ", "perro", " grande. Después vino otro"))
            -- an ellipsis followed by a space ends a sentence too
            assert.are.equal("ahí está el gato…",
                Tokenizer.sentence("Nada. Y así… ahí está el ", "gato", "… y luego"))
        end)
    end)

    describe("states", function()
        it("parses CSV values", function()
            assert.are.equal(States.KNOWN, States.parse("known"))
            assert.are.equal(States.KNOWN, States.parse(" 4 "))
            assert.are.equal(States.LEVEL2, States.parse("2"))
            assert.are.equal(States.IGNORED, States.parse("Ignore"))
            assert.is_nil(States.parse("7"))
            assert.is_nil(States.parse("maybe"))
        end)

        it("colors only new and learning words", function()
            assert.is_true(States.isColored(States.NEW))
            assert.is_true(States.isColored(States.LEVEL3))
            assert.is_false(States.isColored(States.KNOWN))
            assert.is_false(States.isColored(States.IGNORED))
        end)
    end)

    describe("translation view", function()
        -- shaped like Google Translate results (see frontend/ui/translator.lua)
        local sentence_result = {
            { { "He sat on a bench in the park.", "Se sentó en un banco del parque.", nil, nil, 10 } },
            nil, "es",
        }
        local word_result = {
            { { "bank", "banco", nil, nil, 10 } },
            nil, "es", nil, nil,
            { { "banco", nil, { { "bank", 1000, true, false }, { "bench", 0, true, false }, { "the Bank" } } } },
        }

        it("marks the word in the sentence, ignoring case", function()
            assert.are.equal("<b><u>Banco</u></b> y otro <b><u>banco</u></b> &amp; más",
                Translation.markHtml("Banco y otro banco & más",
                    Translation.findWords("Banco y otro banco & más", { "banco" })))
        end)

        it("lists the word's translations without duplicates", function()
            assert.are.same({ "bank", "bench", "the Bank" }, Translation.wordCandidates(word_result))
            assert.are.same({}, Translation.wordCandidates(nil))
        end)

        it("finds the translation that is used in the sentence", function()
            local text = "He sat on a bench in the park."
            assert.are.same({ { 13, 17 } }, Translation.findCandidate(text, { "bank", "bench" }))
            assert.are.same({ { 1, 2 } }, Translation.findCandidate("He realized it.", { "to realize", "he" }))
            assert.are.same({ { 13, 17 } }, Translation.findCandidate(text, { "the bench" }))
            assert.are.same({}, Translation.findCandidate(text, { "seat" }))
        end)

        it("builds the view", function()
            local html = Translation.buildHtml("Se sentó en un banco del parque.", "banco", "banco",
                sentence_result, word_result)
            assert.are.equal("<p>Se sentó en un <b><u>banco</u></b> del parque.</p>\n"
                .. "<p>He sat on a <b><u>bench</u></b> in the park.</p>\n"
                .. "<p><i>banco</i>: bank, bench, the Bank</p>", html)
            assert.is_nil(Translation.buildHtml("x", "x", "x", nil, nil))
        end)
    end)

    describe("csv", function()
        it("round-trips quotes, commas and line breaks", function()
            local row = { "casa", "known", 'house, "home"', "line\nbreak" }
            local parsed = Csv.parse(Csv.formatRow(row) .. "\r\n")
            assert.are.same({ row }, parsed)
        end)

        it("skips a byte order mark and empty lines", function()
            assert.are.same({ { "a", "1" }, { "b", "" } }, Csv.parse("\239\187\191a,1\n\nb,\n"))
        end)
    end)

    describe("store", function()
        local store, path

        before_each(function()
            path = os.tmpname()
            os.remove(path)
            store = Store.open(path, false)
        end)

        after_each(function()
            store:close()
            os.remove(path)
        end)

        it("sets states and records when a word became known", function()
            assert.are.equal(States.NEW, store:setState("es", "perro", States.LEVEL1, { context = "el perro" }))
            assert.are.equal(States.LEVEL1, store:setState("es", "perro", States.KNOWN, { context = "otro" }))
            local row = store:getWord("es", "perro")
            assert.are.equal(States.KNOWN, row.state)
            assert.are.equal("el perro", row.context) -- first context is kept
            assert.is_not_nil(row.known_at)
            store:setState("es", "perro", States.LEVEL2)
            assert.is_nil(store:getWord("es", "perro").known_at)
            assert.are.same({ perro = States.LEVEL2 }, store:loadStates("es"))
            assert.are.same({}, store:loadStates("fr"))
        end)

        it("changes only words in the given state in bulk", function()
            store:setState("es", "gato", States.LEVEL1)
            local changed = store:setStates("es", { "el", "gato", "el", "y" }, States.KNOWN, { only_from = States.NEW })
            assert.are.same({ "el", "y" }, changed)
            assert.are.equal(States.LEVEL1, store:getState("es", "gato"))
        end)

        it("records lookups without changing the state", function()
            store:logLookup("es", "gato", { context = "un gato" })
            store:logLookup("es", "gato", {})
            local row = store:getWord("es", "gato")
            assert.are.equal(2, row.lookups)
            assert.are.equal(States.NEW, row.state)
            assert.are.same({}, store:loadStates("es"))
        end)

        it("keeps several meanings, each with its sentence", function()
            store:addMeaning("es", "banco", "bank", "Fui al banco a sacar dinero.", "Libro", 100)
            store:addMeaning("es", "banco", "bench", "Se sentó en un banco del parque.", "Libro", 200)
            store:addMeaning("es", "banco", "   ", "ignored: empty")
            local meanings = store:getWord("es", "banco").meanings
            assert.are.equal(2, #meanings)
            assert.are.equal("bank", meanings[1].meaning)
            assert.are.equal("Se sentó en un banco del parque.", meanings[2].context)
            assert.are.equal(States.NEW, store:getState("es", "banco"))

            store:updateMeaning(meanings[1].id, "bank (money)")
            assert.are.equal("bank (money)", store:getMeanings("es", "banco")[1].meaning)
            store:updateMeaning(meanings[2].id, "") -- empty deletes
            assert.are.equal(1, #store:getMeanings("es", "banco"))
            store:deleteMeaning(meanings[1].id)
            assert.are.same({}, store:getMeanings("es", "banco"))
        end)

        it("moves a version 1 meaning into the meaning table", function()
            store:close()
            local SQ3 = require("lua-ljsqlite3/init")
            local conn = SQ3.open(path)
            conn:exec([[INSERT INTO word (lang, word, state, meaning, context, created_at, updated_at)
                        VALUES ('es', 'perro', 1, 'dog', 'el perro', 1, 1);
                        PRAGMA user_version=1;]])
            conn:close()
            store = Store.open(path, false)
            local meanings = store:getMeanings("es", "perro")
            assert.are.equal(1, #meanings)
            assert.are.equal("dog", meanings[1].meaning)
            assert.are.equal("el perro", meanings[1].context)
            assert.are.equal("dog", store:listWords("es")[1].meaning)
        end)

        it("computes book stats without ignored words", function()
            local counts, total = Tokenizer.countWords("el perro y el gato y Juan")
            store:saveBookScan("md5", "Libro", "es", counts, total, Tokenizer.VERSION)
            store:setStates("es", { "el", "y" }, States.KNOWN)
            store:setState("es", "perro", States.LEVEL1)
            store:setState("es", "juan", States.IGNORED)
            local stats = store:bookStats("md5", "es")
            assert.are.equal(5, stats.unique)
            assert.are.equal(7, stats.running)
            assert.are.equal(50, stats.known_unique_pct) -- el, y of el, y, perro, gato
            assert.is_true(math.abs(stats.known_running_pct - 400 / 6) < 1e-9)
            assert.are.equal(1, stats.learning_unique)
            assert.are.equal(1, stats.new_unique)
            assert.are.equal(5, store:getBook("md5").unique_words)
            assert.is_nil(store:bookStats("other", "es"))
        end)

        it("reports daily activity", function()
            local now = os.time()
            store:setState("es", "viejo", States.KNOWN, { now = now - 5 * 86400 })
            store:setState("es", "hoy", States.KNOWN, { now = now })
            store:logLookup("es", "gato", { now = now })
            store:addRead("es", 250, 1, now)
            store:addRead("es", 100, 1, now)
            local days = store:activity("es", 3, now)
            assert.are.equal(3, #days)
            local today = days[3]
            assert.are.equal(Store.today(now), today.day)
            assert.are.equal(350, today.words_read)
            assert.are.equal(2, today.pages_read)
            assert.are.equal(1, today.lookups)
            assert.are.equal(1, today.new_known)
            assert.are.equal(2, today.known_total)
            assert.are.equal(1, days[1].known_total)
        end)

        it("exports and imports CSV rows", function()
            store:setState("es", "perro", States.LEVEL1)
            store:addMeaning("es", "perro", "dog", "el perro")
            store:addMeaning("es", "perro", "hound", "el perro de caza")
            local rows = store:exportRows("es")
            assert.are.same(Store.EXPORT_HEADER, rows[1])
            assert.are.equal("perro", rows[2][1])
            assert.are.equal("1", rows[2][2])
            assert.are.equal("dog; hound", rows[2][3])

            local result = store:importRows("es", Csv.parse("word,state,meaning\nCasa,,house\nperro,known,dog\n1984,known\nx,maybe\n"),
                Tokenizer.normalize)
            assert.are.same({ added = 1, updated = 1, unchanged = 0, skipped = 2 }, result)
            assert.are.equal(States.KNOWN, store:getState("es", "casa"))
            assert.are.equal("house", store:getWord("es", "casa").meanings[1].meaning)
            assert.are.equal(2, #store:getMeanings("es", "perro")) -- "dog" not added twice
        end)

        it("lists and deletes words of a language", function()
            store:setState("es", "b", States.KNOWN)
            store:setState("es", "a", States.LEVEL1)
            store:logLookup("es", "c", {})
            store:addMeaning("es", "e", "only a meaning")
            store:setState("fr", "d", States.KNOWN)
            local words = {}
            for _, row in ipairs(store:listWords("es")) do words[#words + 1] = row.word end
            assert.are.same({ "a", "b", "c", "e" }, words)
            assert.are.equal(1, #store:listWords("es", { state = States.KNOWN }))
            assert.are.equal(1, #store:listWords("es", { search = "b" }))
            store:deleteLanguage("es")
            assert.are.equal(0, #store:listWords("es"))
            assert.are.same({}, store:getMeanings("es", "e"))
            assert.are.equal(1, #store:listWords("fr"))
        end)
    end)

    -- A document with crengine's word navigation semantics over a plain text:
    -- xpointers are "#i", the position before character i. Page n starts at
    -- character page_starts[n].
    local function newFakeDocument(text, page_starts)
        local chars, is_word = {}, {}
        for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            chars[#chars + 1] = ch
            is_word[#is_word + 1] = Tokenizer.words(ch)() ~= nil
        end
        local n = #chars
        local function pos(xp) return tonumber(xp:sub(2)) end
        local function isWord(i) return i >= 1 and i <= n and is_word[i] end
        local doc = { page = 1 }
        function doc:getNextVisibleWordStart(xp)
            for j = pos(xp) + 1, n do
                if isWord(j) and not isWord(j - 1) then return "#" .. j end
            end
        end
        function doc:getNextVisibleWordEnd(xp)
            for j = pos(xp) + 1, n + 1 do
                if isWord(j - 1) and not isWord(j) then return "#" .. j end
            end
        end
        function doc:getPrevVisibleChar(xp)
            local i = pos(xp)
            if i > 1 then return "#" .. (i - 1) end
        end
        function doc:compareXPointers(a, b)
            local pa, pb = pos(a), pos(b)
            return pa < pb and 1 or (pa == pb and 0 or -1)
        end
        function doc:getTextFromXPointers(a, b)
            return table.concat(chars, "", pos(a), pos(b) - 1)
        end
        function doc:getPageXPointer(p) return "#" .. page_starts[p] end
        function doc:getPageCount() return #page_starts end
        function doc:getCurrentPage() return self.page end
        function doc:getVisiblePageNumberCount() return 1 end
        function doc:getDocumentRenderingHash() return 42 end
        function doc:getCurrentPos() return self.page * 1000 end
        doc._document = {
            getWordBoxesFromPositions = function(_, a, b)
                -- Only the characters on the current page have a box.
                local first = page_starts[doc.page]
                local last = (page_starts[doc.page + 1] or n + 1) - 1
                local x0, x1 = math.max(pos(a), first), math.min(pos(b) - 1, last)
                if x0 > x1 then return {} end
                return { { x0 = x0 * 10, y0 = 0, x1 = (x1 + 1) * 10, y1 = 10 } }
            end,
        }
        return doc
    end

    describe("overlay", function()
        local text = "uno dos pala" .. "bra tres. Cuatro 5 cinco"
        local function newOverlay(doc)
            local overlay = Overlay:new{ plugin = {} }
            overlay.ui = { document = doc }
            return overlay
        end

        it("collects the words of the current page with their boxes", function()
            local doc = newFakeDocument(text, { 1, 13 }) -- page 2 starts at "bra"
            local overlay = newOverlay(doc)
            local page = overlay:getPage()
            local words = {}
            for _, w in ipairs(page.words) do words[#words + 1] = w.word end
            -- the word hyphenated across the page break belongs to the first page
            assert.are.same({ "uno", "dos", "palabra" }, words)
            assert.are.equal(1, #page.words[3].boxes)
            assert.are.equal(90, page.words[3].boxes[1].x)

            doc.page = 2
            words = {}
            for _, w in ipairs(overlay:getPage().words) do words[#words + 1] = w.word end
            assert.are.same({ "tres", "cuatro", "cinco" }, words)
        end)

        it("finds the word at a screen position", function()
            local doc = newFakeDocument(text, { 1, 13 })
            local overlay = newOverlay(doc)
            assert.is_nil(overlay:wordAt({ x = 15, y = 5 })) -- nothing collected yet
            overlay:getPage()
            assert.are.equal("uno", overlay:wordAt({ x = 15, y = 5 }).word)
            assert.are.equal("dos", overlay:wordAt({ x = 55, y = 5 }).word)
            assert.is_nil(overlay:wordAt({ x = 45, y = 5 })) -- the space
        end)
    end)

    describe("book scan", function()
        it("counts every word once, including words across page breaks", function()
            local sentence = "El niño comió pan. ¿Dónde está el perro? Aquí, en la casa-grande. "
            local text = sentence:rep(12)
            -- a page every 17 characters, so most breaks fall inside words
            local page_starts = {}
            local nchars = select(2, text:gsub("[%z\1-\127\194-\244][\128-\191]*", ""))
            for i = 1, nchars, 17 do page_starts[#page_starts + 1] = i end
            local doc = newFakeDocument(text, page_starts)
            local result
            local scan = BookScan:new{
                ui = { document = doc },
                on_done = function(counts, total) result = { counts = counts, total = total } end,
            }
            scan:start()
            local guard = 0
            while scan.running and guard < 1000 do
                scan:step()
                guard = guard + 1
            end
            scan:cancel()
            local counts, total = Tokenizer.countWords(text)
            assert.is_not_nil(result)
            assert.are.equal(total, result.total)
            assert.are.same(counts, result.counts)
        end)
    end)
end)

#!/usr/bin/env python3
"""Build the grammar database of the Known words plugin from Wiktionary data.

Input: the Spanish word data extracted from English Wiktionary by wiktextract,
as published on kaikki.org (one JSON object per line). Output: an SQLite file
that the plugin reads, mapping every word form to its base word(s) with the
form's grammatical tags, plus each base word's part of speech, gender, short
gloss and full inflection table.

Usage:
    python3 tools/knownwords_build_grammar.py                 # download, then build
    python3 tools/knownwords_build_grammar.py --input FILE    # use a downloaded .jsonl or .jsonl.gz

Then copy the output (grammar_es.sqlite3) into KOReader's settings folder:
~/.config/koreader/settings/ on Linux, .adds/koreader/settings/ on a Kobo.

The data is licensed CC BY-SA (Wiktionary contributors); the plugin shows the
attribution. Only the Python standard library is used.
"""

import argparse
import gzip
import json
import os
import re
import sqlite3
import sys
import time
import unicodedata
import urllib.request

FORMAT_VERSION = 1

DEFAULT_URL = "https://kaikki.org/dictionary/Spanish/kaikki.org-dictionary-Spanish.jsonl"
DOWNLOAD_PAGE = "https://kaikki.org/dictionary/Spanish/"

SCHEMA = """
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE lemma (
    id      INTEGER PRIMARY KEY,
    word    TEXT NOT NULL,
    norm    TEXT NOT NULL,
    pos     TEXT NOT NULL,
    gender  TEXT,
    gloss   TEXT
);
CREATE TABLE tagset (
    id      INTEGER PRIMARY KEY,
    tags    TEXT NOT NULL UNIQUE    -- space-separated wiktextract tags, sorted
);
CREATE TABLE form (
    norm     TEXT NOT NULL,     -- normalized last word of the form, as tapped in a text
    lemma_id INTEGER NOT NULL,
    tagset   INTEGER NOT NULL,
    in_table INTEGER NOT NULL,  -- 1 if it comes from the base word's inflection table
    form     TEXT,              -- the form as written, only if not norm ("me lavo", "Hablo")
    note     TEXT               -- the gloss, when there are no tags ("diminutive of ...")
);
-- Removes duplicates while building; dropped at the end.
CREATE UNIQUE INDEX form_unique_index ON form (norm, lemma_id, tagset, IFNULL(form, ''));
"""

INDEXES = """
DROP INDEX form_unique_index;
CREATE INDEX lemma_norm_index ON lemma (norm);
CREATE INDEX form_norm_index ON form (norm);
CREATE INDEX form_lemma_index ON form (lemma_id, in_table);
"""

# Rows of the inflection table that are not forms.
SKIP_FORM_TAGS = {"table-tags", "class", "inflection-template", "romanization", "canonical"}

SOFT_HYPHEN = "­"


def normalize(word):
    """Normalizes a word like the plugin does (NFKC, case folding, no soft hyphens)."""
    return unicodedata.normalize("NFKC", word.replace(SOFT_HYPHEN, "")).casefold()


def key_of(form):
    """The word a reader taps for a form: its last word ("me lavo" -> "lavo")."""
    parts = form.split()
    return normalize(parts[-1]) if parts else ""


GENDER_RE = re.compile(r"^\S+ (m or f|mf|m|f|n)(?: pl)?\b")


def gender_of(entry):
    genders = set()
    for sense in entry.get("senses", []):
        tags = sense.get("tags", [])
        if "masculine" in tags:
            genders.add("m")
        if "feminine" in tags:
            genders.add("f")
    for head in entry.get("head_templates", []):
        m = GENDER_RE.match(head.get("expansion", ""))
        if m:
            g = m.group(1)
            if g in ("m or f", "mf"):
                genders.update(("m", "f"))
            else:
                genders.add(g)
    if not genders:
        return None
    return "/".join(sorted(genders, key="mfn".index))


def gloss_of(senses):
    glosses = []
    for sense in senses:
        for g in sense.get("glosses", [])[:1]:
            if g and g not in glosses:
                glosses.append(g)
        if len(glosses) >= 3:
            break
    text = "; ".join(glosses)
    return text[:200] + "…" if len(text) > 200 else (text or None)


def is_form_sense(sense):
    return bool(sense.get("form_of") or sense.get("alt_of"))


def open_input(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8")
    return open(path, encoding="utf-8")


def download(url, dest):
    print(f"Downloading {url}")
    print("(about 1 GB; this can take a while)")
    tmp = dest + ".part"
    try:
        with urllib.request.urlopen(url) as response, open(tmp, "wb") as out:
            total = int(response.headers.get("Content-Length") or 0)
            done = 0
            last = 0
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                out.write(chunk)
                done += len(chunk)
                if time.time() - last > 2:
                    last = time.time()
                    if total:
                        print(f"  {done >> 20} / {total >> 20} MB", flush=True)
                    else:
                        print(f"  {done >> 20} MB", flush=True)
    except Exception as e:  # noqa: BLE001 - report any network failure the same way
        if os.path.exists(tmp):
            os.remove(tmp)
        sys.exit(f"Download failed: {e}\n"
                 f"Download the Spanish JSONL file by hand from {DOWNLOAD_PAGE}\n"
                 f"and run again with --input <file>.")
    os.replace(tmp, dest)


class Builder:
    def __init__(self, conn, lang_code):
        self.conn = conn
        self.lang_code = lang_code
        self.lemma_ids = {}      # (norm, pos) -> id
        self.lemma_by_norm = {}  # norm -> first id
        self.links = []          # (form word, target word, pos, tags, note)
        self.tagsets = {}        # tags text -> id
        self.pronoun_forms = True
        self.counts = {"entries": 0, "lemmas": 0, "forms": 0}

    def add_lemma(self, word, pos, gender=None, gloss=None):
        norm = normalize(word)
        key = (norm, pos)
        if key in self.lemma_ids:
            return self.lemma_ids[key]
        cur = self.conn.execute(
            "INSERT INTO lemma (word, norm, pos, gender, gloss) VALUES (?, ?, ?, ?, ?)",
            (word, norm, pos, gender, gloss))
        lemma_id = cur.lastrowid
        self.lemma_ids[key] = lemma_id
        self.lemma_by_norm.setdefault(norm, lemma_id)
        self.counts["lemmas"] += 1
        return lemma_id

    def tagset_id(self, tags):
        text = " ".join(sorted(set(tags)))
        tagset = self.tagsets.get(text)
        if tagset is None:
            tagset = self.conn.execute("INSERT INTO tagset (tags) VALUES (?)", (text,)).lastrowid
            self.tagsets[text] = tagset
        return tagset

    def add_form(self, form, lemma_id, tags, in_table, note=None):
        norm = key_of(form)
        if not norm:
            return
        if not self.pronoun_forms and "combined-form" in tags:
            return
        cur = self.conn.execute(
            "INSERT OR IGNORE INTO form (norm, lemma_id, tagset, in_table, form, note) VALUES (?, ?, ?, ?, ?, ?)",
            (norm, lemma_id, self.tagset_id(tags), in_table, None if form == norm else form, note))
        self.counts["forms"] += cur.rowcount

    def entry(self, e):
        if e.get("lang_code") != self.lang_code:
            return
        word, pos = e.get("word"), e.get("pos")
        if not word or not pos:
            return
        self.counts["entries"] += 1
        senses = e.get("senses", [])
        form_senses = [s for s in senses if is_form_sense(s)]
        # Senses that say "form of X" become links, resolved once all base words are known.
        for s in form_senses:
            tags = [t for t in s.get("tags", []) if t not in ("form-of", "alt-of")]
            targets = s.get("form_of") or []
            if not targets:
                targets = s.get("alt_of") or []
                tags = tags or ["alternative"]
            note = None if tags else (s.get("glosses") or [None])[0]
            for t in targets:
                if t.get("word"):
                    self.links.append((word, t["word"], pos, tags, note))
        if senses and len(form_senses) == len(senses):
            return  # a pure form entry: not a base word
        lemma_id = self.add_lemma(word, pos, gender_of(e),
                                  gloss_of([s for s in senses if not is_form_sense(s)]))
        for f in e.get("forms", []):
            form, tags = f.get("form"), f.get("tags", [])
            if not form or form == "-" or SKIP_FORM_TAGS.intersection(tags):
                continue
            self.add_form(form, lemma_id, tags, 1)

    def resolve_links(self):
        for form, target, pos, tags, note in self.links:
            norm = normalize(target)
            lemma_id = self.lemma_ids.get((norm, pos)) or self.lemma_by_norm.get(norm)
            if lemma_id is None:
                lemma_id = self.add_lemma(target, pos)  # base word without an entry of its own
            self.add_form(form, lemma_id, tags, 0, note)


def build(input_path, output_path, lang_code, pronoun_forms=True):
    if os.path.exists(output_path):
        os.remove(output_path)
    conn = sqlite3.connect(output_path)
    conn.executescript(SCHEMA)
    builder = Builder(conn, lang_code)
    builder.pronoun_forms = pronoun_forms
    start = time.time()
    with open_input(input_path) as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                builder.entry(json.loads(line))
            except json.JSONDecodeError:
                continue
            if n % 100000 == 0:
                print(f"  {n} lines, {builder.counts['lemmas']} base words, "
                      f"{builder.counts['forms']} forms", flush=True)
    builder.resolve_links()
    conn.executescript(INDEXES)
    meta = {
        "format": str(FORMAT_VERSION),
        "lang": lang_code,
        "source": "Wiktionary (English edition) via wiktextract/kaikki.org, CC BY-SA",
        "built": time.strftime("%Y-%m-%d"),
        "lemmas": str(builder.counts["lemmas"]),
        "forms": str(builder.counts["forms"]),
    }
    conn.executemany("INSERT INTO meta (key, value) VALUES (?, ?)", meta.items())
    conn.commit()
    conn.execute("VACUUM")
    conn.close()
    size = os.path.getsize(output_path) >> 20
    print(f"Done in {time.time() - start:.0f} s: {builder.counts['lemmas']} base words, "
          f"{builder.counts['forms']} forms, {size} MB -> {output_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--input", help="kaikki.org .jsonl or .jsonl.gz file (downloaded if omitted)")
    parser.add_argument("--output", default="grammar_es.sqlite3", help="output file (default: %(default)s)")
    parser.add_argument("--url", default=DEFAULT_URL, help="download URL (default: %(default)s)")
    parser.add_argument("--lang", default="es", help="Wiktionary language code (default: %(default)s)")
    parser.add_argument("--no-pronoun-forms", action="store_true",
                        help="leave out verb forms with attached pronouns (dámelo...), for a smaller file")
    args = parser.parse_args()
    input_path = args.input
    if not input_path:
        input_path = os.path.basename(args.url)
        if not os.path.exists(input_path):
            download(args.url, input_path)
    build(input_path, args.output, args.lang, pronoun_forms=not args.no_pronoun_forms)


if __name__ == "__main__":
    main()

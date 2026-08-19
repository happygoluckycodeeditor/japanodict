#!/usr/bin/env python3
"""
Build a clean dictionary SQLite database from the official Jitendex Yomitan
release (https://github.com/stephenmk/stephenmk.github.io).

The previous `jitendex_flattened.db` mashed each entry's definitions, example
sentences, furigana and cross-references into one text blob and — for many
entries — dropped the primary definition entirely. This script parses the
Yomitan "structured content" properly, keeping:

  * definitions (glosses), grouped by sense, definitions only
  * parts of speech
  * example sentences (Japanese + English), stored separately so they never
    pollute search or the definition list

Usage:
    python3 scripts/build_dictionary_db.py <path/to/jitendex_src_dir> [out.db]

<jitendex_src_dir> is the unzipped Jitendex Yomitan release (the folder that
contains term_bank_*.json and index.json).
"""

import glob
import json
import os
import re
import sqlite3
import sys

FOOTNOTE = re.compile(r'\[\d+\]$')


def data_content(node):
    if isinstance(node, dict):
        d = node.get('data')
        if isinstance(d, dict):
            return d.get('content')
    return None


def node_text(node, skip_rt=True):
    """Flatten a node to plain text. Ruby readings (<rt>) are skipped so
    example sentences read as their base text."""
    if isinstance(node, str):
        return node
    if isinstance(node, list):
        return ''.join(node_text(n, skip_rt) for n in node)
    if isinstance(node, dict):
        if skip_rt and node.get('tag') == 'rt':
            return ''
        return node_text(node.get('content', ''), skip_rt)
    return ''


def walk(node, cb):
    cb(node)
    if isinstance(node, dict):
        walk(node.get('content'), cb)
    elif isinstance(node, list):
        for n in node:
            walk(n, cb)


def collect_li_texts(node):
    """Return the text of each <li> under a node (each is one gloss)."""
    out = []

    def cb(n):
        if isinstance(n, dict) and n.get('tag') == 'li':
            t = node_text(n).strip()
            if t:
                out.append(t)
    walk(node, cb)
    return out


def extract(content):
    """Return (glosses_string, pos_string, examples[list of (ja,en)])."""
    senses = []       # each sense is a list of gloss strings
    pos = []
    seen_pos = set()
    examples = []

    def cb(node):
        dc = data_content(node)
        if dc == 'glossary':
            glosses = collect_li_texts(node)
            if not glosses:
                t = node_text(node).strip()
                if t:
                    glosses = [t]
            if glosses:
                senses.append(glosses)
        elif dc == 'part-of-speech-info':
            t = node_text(node).strip()
            if t and t not in seen_pos:
                seen_pos.add(t)
                pos.append(t)
        elif dc == 'example-sentence':
            ja = en = ''

            def cb2(n):
                nonlocal ja, en
                d2 = data_content(n)
                if d2 == 'example-sentence-a':
                    ja = node_text(n).strip()
                elif d2 == 'example-sentence-b':
                    en = node_text(n).strip()
            walk(node, cb2)
            ja = FOOTNOTE.sub('', ja).strip()
            en = FOOTNOTE.sub('', en).strip()
            if ja:
                examples.append((ja, en))

    walk(content, cb)

    # A sense's glosses are joined with "; "; senses are joined with " • ",
    # so DictionaryEntry.glossList (which splits on •) yields one bullet per
    # sense.
    sense_strings = ['; '.join(g) for g in senses]
    glosses_string = ' • '.join(sense_strings)
    pos_string = ', '.join(pos)
    return glosses_string, pos_string, examples


SCHEMA = """
DROP TABLE IF EXISTS dictionary;
DROP TABLE IF EXISTS dictionary_fts;
DROP TABLE IF EXISTS examples;

CREATE TABLE dictionary (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    term TEXT NOT NULL,
    reading TEXT,
    glosses TEXT NOT NULL,
    parts_of_speech TEXT,
    tags TEXT,
    score INTEGER,
    sequence INTEGER,
    is_common INTEGER NOT NULL DEFAULT 0,
    jlpt TEXT,
    -- Corpus frequency rank, 1 = most frequent, NULL = not in the corpus.
    -- Left NULL here: it comes from a separate source and is written by
    -- scripts/build_freq_db.py, which must be re-run after this script or
    -- search ranking loses its only tiebreaker between two common words.
    freq INTEGER
);
CREATE INDEX idx_term ON dictionary(term);
CREATE INDEX idx_reading ON dictionary(reading);
CREATE INDEX idx_score ON dictionary(score DESC);
CREATE INDEX idx_common ON dictionary(is_common DESC);
CREATE INDEX idx_jlpt ON dictionary(jlpt);

CREATE VIRTUAL TABLE dictionary_fts USING fts4(
    term, reading, glosses,
    content='dictionary', tokenize=unicode61
);

CREATE TABLE examples (
    entry_id INTEGER,
    ja TEXT,
    en TEXT
);
CREATE INDEX idx_ex_entry ON examples(entry_id);
"""


def apply_jlpt(cur, jlpt_path):
    """Tag entries with JLPT levels from a community word list
    ({term: [{reading, level}]}, where level 5==N5 ... 1==N1).

    JLPT data is NOT part of JMdict/Jitendex — it comes from the community
    Tanos lists (the same source Jisho uses). Tagging is propagated to the
    whole word (sequence) using the easiest matched level, so every spelling
    of a JLPT word shows the badge — matching how Jisho tags words."""
    print(f"Applying JLPT levels from {jlpt_path} ...")
    jlpt = json.load(open(jlpt_path))
    pair_level = {}
    for term, arr in jlpt.items():
        for x in arr:
            pair_level[(term, x['reading'])] = x['level']

    cur.execute("SELECT id, term, reading, sequence FROM dictionary")
    rows = cur.fetchall()
    seq_level = {}
    for _id, term, reading, seq in rows:
        lvl = pair_level.get((term, reading or ''))
        if lvl:
            # Highest number == easiest level (N5); a word is tagged at the
            # easiest level any of its forms appears at.
            seq_level[seq] = max(seq_level.get(seq, 0), lvl)

    updates = [(f'N{seq_level[seq]}', _id)
               for _id, term, reading, seq in rows if seq in seq_level]
    cur.executemany("UPDATE dictionary SET jlpt = ? WHERE id = ?", updates)
    print(f"  tagged {len(updates):,} entries across {len(seq_level):,} words")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else 'jitendex.db'
    jlpt_path = sys.argv[3] if len(sys.argv) > 3 else None

    if os.path.exists(out):
        os.remove(out)
    conn = sqlite3.connect(out)
    cur = conn.cursor()
    cur.executescript(SCHEMA)

    banks = sorted(glob.glob(os.path.join(src, 'term_bank_*.json')),
                   key=lambda p: int(re.search(r'_(\d+)\.json', p).group(1)))
    print(f"Found {len(banks)} term banks")

    # Pass 1: a word (sequence) is "common" if ANY of its forms/readings is
    # marked with the ★ priority star — the same rule Jisho uses. This is why
    # a rare kanji spelling (発条) of a common word (ばね) still counts common.
    print("Pass 1: finding common words...")
    common_sequences = set()
    for bank in banks:
        for e in json.load(open(bank)):
            def_tags, sequence = e[2] or '', e[6]
            if '★' in def_tags:
                common_sequences.add(sequence)
    print(f"  {len(common_sequences):,} common word-groups")

    print("Pass 2: importing entries...")
    entry_id = 0
    total_examples = 0
    MAX_EXAMPLES = 5  # per entry, keeps the DB lean
    for bi, bank in enumerate(banks, 1):
        rows = json.load(open(bank))
        for e in rows:
            term, reading, def_tags, rules, score, content, sequence, term_tags = e
            glosses, pos, examples = extract(content)
            if not glosses:
                continue
            entry_id += 1
            tags = (term_tags or '').strip()
            is_common = 1 if sequence in common_sequences else 0
            cur.execute(
                "INSERT INTO dictionary(id, term, reading, glosses, parts_of_speech, tags, score, sequence, is_common) "
                "VALUES (?,?,?,?,?,?,?,?,?)",
                (entry_id, term, reading or None, glosses, pos or None,
                 tags or None, score, sequence, is_common))
            for ja, en in examples[:MAX_EXAMPLES]:
                cur.execute("INSERT INTO examples(entry_id, ja, en) VALUES (?,?,?)",
                            (entry_id, ja, en))
                total_examples += 1
        if bi % 25 == 0:
            print(f"  {bi}/{len(banks)} banks, {entry_id:,} entries")
            conn.commit()

    if jlpt_path:
        apply_jlpt(cur, jlpt_path)
        conn.commit()

    print("Populating FTS index...")
    cur.execute(
        "INSERT INTO dictionary_fts(docid, term, reading, glosses) "
        "SELECT id, term, reading, glosses FROM dictionary")
    conn.commit()

    print(f"✓ {entry_id:,} entries, {total_examples:,} examples")
    cur.execute("VACUUM")
    conn.close()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Add a proper-name `names` table to the prebuilt dictionary database from
JMnedict (http://ftp.edrdg.org/pub/Nihongo/JMnedict.xml.gz).

Jitendex is a JMdict rebuild, and **JMdict holds no proper names at all** — so
searching for "Godzilla" or "Nintendo" returned nothing while Shirabe Jisho and
Takoboto found them instantly. Those apps bundle the EDRDG's *second*
dictionary alongside the first. This imports the useful part of it.

Only 17k of JMnedict's 743,603 entries are imported, and the filter is the
whole point of this script — see NOISE below.

This deliberately does NOT rebuild the dictionary tables. It only drops and
recreates `names` and `names_fts`, so re-slicing the filter doesn't mean
re-downloading the Jitendex release and re-importing 296k entries.

Usage:
    curl -sL -o JMnedict.xml.gz http://ftp.edrdg.org/pub/Nihongo/JMnedict.xml.gz
    gunzip JMnedict.xml.gz
    python3 scripts/build_names_db.py JMnedict.xml assets/databases/jitendex.db

Remember to bump `DatabaseService._dbVersion` afterwards, or existing installs
will keep querying their old copy without the names table.

JMnedict is Copyright (C) The Electronic Dictionary Research and Development
Group, licensed CC BY-SA 4.0 — the same licence and the same attribution
obligation as JMdict and KANJIDIC2.
"""

import os
import sqlite3
import sys
import xml.etree.ElementTree as ET

# JMnedict ships its DTD inline, and ElementTree **expands the entities**. So
# `<name_type>&company;</name_type>` parses as the text 'company name', not as
# 'company'. Filtering on the short tag silently matches nothing — it looks
# like a working import that kept 64 of 743,603 entries. Map back by hand.
TAG = {
    'place name': 'place',
    'family or surname': 'surname',
    'unclassified name': 'unclass',
    'female given name or forename': 'fem',
    'given name or forename, gender not specified': 'given',
    'full name of a particular person': 'person',
    'male given name or forename': 'masc',
    'railway station': 'station',
    'organization name': 'organization',
    'company name': 'company',
    'work of art, literature, music, etc. name': 'work',
    'product name': 'product',
    'service': 'serv',
    'character': 'char',
    'event': 'ev',
    'fiction': 'fict',
    'group': 'group',
    'deity': 'dei',
    'object': 'obj',
    'mythology': 'myth',
    'creature': 'creat',
    'document': 'doc',
    'ship name': 'ship',
    'legend': 'leg',
}

# The types worth importing: things a learner looks *up*, as opposed to things
# that merely have a name.
#
# `station` is in because this app gets pointed at signage through OCR, and
# station names are most of what a sign says.
KEEP = {
    'company', 'product', 'work', 'organization', 'char', 'fict', 'ev',
    'serv', 'group', 'dei', 'obj', 'myth', 'creat', 'doc', 'ship', 'leg',
    'station',
}

# Everything else, and why it stays out. 672k of the 743k entries are personal
# and place names, and importing them is actively harmful rather than merely
# large:
#
#   * `unclass` (130k) is romaji transliterations of personal names —
#     佑文 "Masabumi", 位攣 "Akiko". Nothing a dictionary user wants.
#   * measured against the shipped database, the full import puts 19 name
#     entries on 一, 18 on 心, 16 on 山 and 11 on 花 — all competing with the
#     words that search's ranking works hard to order correctly.
#   * the full set costs +112MB against an asset that is already ~87MB.
#
# The kept slice adds 0 hits on every one of those common words.
NOISE = {'place', 'surname', 'unclass', 'fem', 'given', 'person', 'masc'}

SCHEMA = """
DROP TABLE IF EXISTS names_fts;
DROP TABLE IF EXISTS names;

CREATE TABLE names (
    id INTEGER PRIMARY KEY,
    sequence INTEGER NOT NULL,
    term TEXT NOT NULL,
    reading TEXT,
    name_type TEXT,
    priority INTEGER NOT NULL DEFAULT 0,
    glosses TEXT NOT NULL
);
CREATE INDEX idx_names_term ON names(term);
CREATE INDEX idx_names_reading ON names(reading);
CREATE INDEX idx_names_sequence ON names(sequence);

CREATE VIRTUAL TABLE names_fts USING fts4(
    term, reading, glosses, content='names', tokenize=unicode61
);
"""


def parse_entry(el):
    """Return row tuples for one <entry>, or [] if it is filtered out.

    One row per spelling, mirroring how `dictionary` stores a word's several
    spellings under a shared `sequence` — so the same collapse-by-sequence the
    search already does works here unchanged.
    """
    seq = el.findtext('ent_seq')
    if not seq or not seq.isdigit():
        return []

    types, senses = set(), []
    for trans in el.iterfind('trans'):
        for nt in trans.iterfind('name_type'):
            types.add(TAG.get((nt.text or '').strip(), 'unclass'))
        # Glosses within one <trans> are one sense; joined by '; ', senses by
        # ' • ' — the convention `DictionaryEntry.glossList` already splits on.
        dets = [d.text.strip() for d in trans.iterfind('trans_det') if d.text]
        if dets:
            senses.append('; '.join(dets))

    if not senses or not (types & KEEP):
        return []

    glosses = ' • '.join(senses)
    name_type = ','.join(sorted(types))

    kebs = [k.text for k in el.iterfind('k_ele/keb') if k.text]
    rebs = [r.text for r in el.iterfind('r_ele/reb') if r.text]

    # A priority tag (spec1 and friends) is JMnedict's only ranking signal —
    # it is what puts ゴジラ and 任天堂 above same-named obscurities.
    priority = 1 if (el.find('.//re_pri') is not None
                     or el.find('.//ke_pri') is not None) else 0

    rows = []
    if kebs:
        # Kanji spellings carry the first reading; a kana-only entry is its own
        # reading, kept populated so the FTS and the reading index both match
        # it. The UI hides a reading equal to its term.
        reading = rebs[0] if rebs else None
        for k in kebs:
            rows.append((int(seq), k, reading, name_type, priority, glosses))
    else:
        for r in rebs:
            rows.append((int(seq), r, r, name_type, priority, glosses))
    return rows


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    xml_path, db_path = sys.argv[1], sys.argv[2]

    if not os.path.exists(db_path):
        print(f"error: {db_path} does not exist — build the dictionary first")
        sys.exit(1)

    print(f"Parsing {xml_path} ...")
    rows, total, kept_types = [], 0, {}
    for event, el in ET.iterparse(xml_path, events=('end',)):
        if el.tag != 'entry':
            continue
        total += 1
        entry_rows = parse_entry(el)
        for r in entry_rows:
            for t in r[3].split(','):
                kept_types[t] = kept_types.get(t, 0) + 1
        rows.extend(entry_rows)
        # JMnedict is ~150MB of XML; without this the whole tree stays live.
        el.clear()

    sequences = len({r[0] for r in rows})
    print(f"  {total:,} entries in JMnedict")
    print(f"  {sequences:,} kept ({len(rows):,} rows across their spellings)")
    for t, n in sorted(kept_types.items(), key=lambda kv: -kv[1]):
        marker = '' if t in KEEP else '   (carried in on a multi-type entry)'
        print(f"      {t:<14} {n:>6,}{marker}")

    if not rows:
        print("error: nothing matched the filter — did the DTD entity names "
              "change? See TAG above.")
        sys.exit(1)

    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.executescript(SCHEMA)
    cur.executemany(
        "INSERT INTO names(sequence, term, reading, name_type, priority, "
        "glosses) VALUES (?,?,?,?,?,?)", rows)
    cur.execute("INSERT INTO names_fts(names_fts) VALUES('rebuild')")
    conn.commit()

    cur.execute("SELECT COUNT(*) FROM names")
    print(f"✓ names table: {cur.fetchone()[0]:,} rows")

    # A quick self-check on the words that motivated this import. If the filter
    # or the entity mapping breaks, this is what says so.
    for probe in ('ゴジラ', '任天堂', 'ポケモン', '鬼滅の刃'):
        cur.execute("SELECT glosses FROM names WHERE term = ?", (probe,))
        hit = cur.fetchone()
        print(f"    {probe:<8} {hit[0] if hit else '!! MISSING !!'}")

    cur.execute("VACUUM")
    conn.close()
    print("Remember to bump DatabaseService._dbVersion.")


if __name__ == "__main__":
    main()

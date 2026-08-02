#!/usr/bin/env python3
"""
Add a per-character `kanji` table to the prebuilt dictionary database from
KANJIDIC2 (http://www.edrdg.org/kanjidic/kanjidic2.xml.gz).

Jitendex/JMdict is vocabulary-level — it has no per-character data at all, so
the detail view can't show "which kanji are in this word, and what does each
one mean" without a second source. KANJIDIC2 supplies that: meanings, on/kun
readings, stroke count, school grade and frequency rank per character.

This deliberately does NOT rebuild the dictionary tables. It only drops and
recreates `kanji`, so iterating on kanji data doesn't mean re-downloading the
~80MB Jitendex release and re-importing every entry.

Usage:
    curl -sL -o kanjidic2.xml.gz http://www.edrdg.org/kanjidic/kanjidic2.xml.gz
    gunzip kanjidic2.xml.gz
    python3 scripts/build_kanji_db.py kanjidic2.xml assets/databases/jitendex.db

Remember to bump `DatabaseService._dbVersion` afterwards, or existing installs
will keep querying their old copy without the kanji table.

KANJIDIC2 is Copyright (C) The Electronic Dictionary Research and Development
Group, licensed CC BY-SA 4.0. Attribution is required in the shipping app.
"""

import os
import sqlite3
import sys
import xml.etree.ElementTree as ET

SCHEMA = """
DROP TABLE IF EXISTS kanji;

CREATE TABLE kanji (
    literal TEXT PRIMARY KEY,
    grade INTEGER,
    stroke_count INTEGER,
    freq INTEGER,
    jlpt_old INTEGER,
    on_readings TEXT,
    kun_readings TEXT,
    meanings TEXT,
    nanori TEXT
);
CREATE INDEX idx_kanji_grade ON kanji(grade);
CREATE INDEX idx_kanji_strokes ON kanji(stroke_count);
"""


def parse_character(c):
    """Return a row tuple for one <character>, or None if it has no English
    meaning (a few thousand JIS X 0212 entries are readings-only and would
    render as an empty card)."""
    literal = c.findtext('literal')
    if not literal:
        return None

    misc = c.find('misc')
    grade = stroke_count = freq = jlpt_old = None
    if misc is not None:
        grade = misc.findtext('grade')
        # stroke_count can repeat — the first is the accepted count, any
        # others are common miscounts. Only the first is wanted.
        sc = misc.find('stroke_count')
        stroke_count = sc.text if sc is not None else None
        freq = misc.findtext('freq')
        jlpt_old = misc.findtext('jlpt')

    on, kun, meanings, nanori = [], [], [], []
    rm = c.find('reading_meaning')
    if rm is not None:
        # Multiple rmgroups are rare but legal; merge them.
        for group in rm.findall('rmgroup'):
            for r in group.findall('reading'):
                rtype = r.get('r_type')
                if rtype == 'ja_on' and r.text:
                    on.append(r.text)
                elif rtype == 'ja_kun' and r.text:
                    kun.append(r.text)
            for m in group.findall('meaning'):
                # A meaning with no m_lang attribute is English; the others
                # are French/Spanish/Portuguese and would pollute the card.
                if m.get('m_lang') is None and m.text:
                    meanings.append(m.text)
        for n in rm.findall('nanori'):
            if n.text:
                nanori.append(n.text)

    if not meanings:
        return None

    def as_int(v):
        return int(v) if v and v.isdigit() else None

    return (
        literal,
        as_int(grade),
        as_int(stroke_count),
        as_int(freq),
        as_int(jlpt_old),
        ', '.join(on) or None,
        ', '.join(kun) or None,
        ', '.join(meanings),
        ', '.join(nanori) or None,
    )


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    xml_path, db_path = sys.argv[1], sys.argv[2]

    if not os.path.exists(db_path):
        print(f"error: {db_path} does not exist — build the dictionary first")
        sys.exit(1)

    print(f"Parsing {xml_path} ...")
    root = ET.parse(xml_path).getroot()
    characters = root.findall('character')
    print(f"  {len(characters):,} characters in KANJIDIC2")

    rows = [r for r in (parse_character(c) for c in characters) if r]
    skipped = len(characters) - len(rows)
    print(f"  {len(rows):,} with English meanings ({skipped:,} skipped)")

    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.executescript(SCHEMA)
    cur.executemany(
        "INSERT INTO kanji(literal, grade, stroke_count, freq, jlpt_old, "
        "on_readings, kun_readings, meanings, nanori) "
        "VALUES (?,?,?,?,?,?,?,?,?)", rows)
    conn.commit()

    cur.execute("SELECT COUNT(*) FROM kanji")
    print(f"✓ kanji table: {cur.fetchone()[0]:,} rows")
    cur.execute("VACUUM")
    conn.close()
    print("Remember to bump DatabaseService._dbVersion.")


if __name__ == "__main__":
    main()

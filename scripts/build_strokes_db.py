#!/usr/bin/env python3
"""
Add a `kanji_strokes` table (stroke-order outlines) to the prebuilt dictionary
database from KanjiVG (https://github.com/KanjiVG/kanjivg).

KANJIDIC2 gives a *stroke count* but no geometry, so it can't answer "how is
this character written". KanjiVG supplies one SVG path per stroke, already in
writing order, which is what the stroke-order diagram in the detail sheet
draws.

Like `build_kanji_db.py`, this only drops and recreates its own table — the
dictionary and kanji tables are left untouched, so this can be re-run cheaply.

Usage:
    curl -sL -o kanjivg.xml.gz \\
      https://github.com/KanjiVG/kanjivg/releases/latest/download/kanjivg-<date>.xml.gz
    gunzip kanjivg.xml.gz
    python3 scripts/build_strokes_db.py kanjivg.xml assets/databases/jitendex.db

(Check the releases page for the current filename; the tag is date-stamped.)

Remember to bump `DatabaseService._dbVersion` afterwards.

KanjiVG is Copyright (C) Ulrich Apel, licensed CC BY-SA 3.0. Attribution is
required in the shipping app.
"""

import os
import re
import sqlite3
import sys

# <kanji id="kvg:kanji_04e09">  →  codepoint 0x4e09 (三)
KANJI_RE = re.compile(r'<kanji id="kvg:kanji_([0-9a-f]+)"(.*?)</kanji>', re.S)
# <path id="kvg:04e09-s1" ... d="M27.5,23.65c..."/>  →  (stroke number, outline)
PATH_RE = re.compile(r'<path[^>]*?id="kvg:[0-9a-f]+-s(\d+)"[^>]*?\sd="([^"]+)"')

SCHEMA = """
DROP TABLE IF EXISTS kanji_strokes;

CREATE TABLE kanji_strokes (
    literal TEXT PRIMARY KEY,
    stroke_count INTEGER NOT NULL,
    paths TEXT NOT NULL
);
"""

# KanjiVG draws every character into a fixed square viewBox. The renderer
# needs this to scale outlines to whatever size it's drawing at.
VIEWBOX = 109


def parse(xml_text):
    """Yield (literal, stroke_count, newline-joined path data) per character."""
    for codepoint_hex, body in KANJI_RE.findall(xml_text):
        strokes = PATH_RE.findall(body)
        if not strokes:
            continue

        # Order by the stroke number in the id rather than trusting document
        # order — the paths are nested inside radical <g> groups, so document
        # order is not guaranteed to be writing order.
        strokes.sort(key=lambda s: int(s[0]))
        outlines = [d.strip() for _, d in strokes]

        try:
            literal = chr(int(codepoint_hex, 16))
        except ValueError:
            continue

        yield literal, len(outlines), '\n'.join(outlines)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    xml_path, db_path = sys.argv[1], sys.argv[2]

    if not os.path.exists(db_path):
        print(f"error: {db_path} does not exist — build the dictionary first")
        sys.exit(1)

    print(f"Parsing {xml_path} ...")
    with open(xml_path, encoding='utf-8') as f:
        xml_text = f.read()

    rows = list(parse(xml_text))
    print(f"  {len(rows):,} characters with stroke data")

    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.executescript(SCHEMA)
    cur.executemany(
        "INSERT INTO kanji_strokes(literal, stroke_count, paths) VALUES (?,?,?)",
        rows)
    conn.commit()

    cur.execute("SELECT COUNT(*) FROM kanji_strokes")
    print(f"✓ kanji_strokes table: {cur.fetchone()[0]:,} rows (viewBox {VIEWBOX})")

    # Sanity check: stroke counts should agree with KANJIDIC2 for characters
    # present in both. A handful of legitimate disagreements exist (the two
    # projects occasionally split strokes differently), but a large number
    # would mean the ordering or parsing is wrong.
    try:
        cur.execute("""
            SELECT COUNT(*) FROM kanji_strokes s
            JOIN kanji k ON k.literal = s.literal
            WHERE k.stroke_count IS NOT NULL AND k.stroke_count != s.stroke_count
        """)
        mismatched = cur.fetchone()[0]
        cur.execute("""
            SELECT COUNT(*) FROM kanji_strokes s JOIN kanji k ON k.literal = s.literal
        """)
        shared = cur.fetchone()[0]
        print(f"  stroke-count cross-check vs KANJIDIC2: "
              f"{shared - mismatched:,}/{shared:,} agree")
    except sqlite3.OperationalError:
        print("  (kanji table absent — skipped cross-check)")

    cur.execute("VACUUM")
    conn.close()
    print("Remember to bump DatabaseService._dbVersion.")


if __name__ == "__main__":
    main()

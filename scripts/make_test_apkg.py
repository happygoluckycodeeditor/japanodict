#!/usr/bin/env python3
"""Builds throwaway Anki deck packages for testing the importer.

The `.apkg` half of `lib/services/anki_import_service.dart` cannot be covered
by `flutter test`: it opens the collection with sqflite, which is a platform
channel and needs a device. This script produces the files to point a device
build at instead, so "does importing work" is a repeatable check rather than a
hunt for a real deck to try.

Three shapes are written, because the importer branches on all three:

  legacy.apkg   schema 11 — one JSON blob in `col` holds the note types and the
                deck tree. This is what Anki writes when "Support older Anki
                versions" is ticked, which is what the app tells users to do.
  modern.apkg   schema 18 — real `notetypes`/`fields`/`decks` tables. Still
                plain SQLite, so still readable.
  newformat.apkg  the zstd-compressed `collection.anki21b` Anki 2.1.50+ writes
                by default. Nothing can read this without a zstd decoder; it is
                here to check the app *says so* instead of failing obscurely.

Usage:
    python3 scripts/make_test_apkg.py /tmp/anki-fixtures
"""

import json
import os
import sqlite3
import sys
import zipfile

SEP = "\x1f"

# Deliberately dirty: every note below carries something the field cleaner has
# to deal with, so a broken cleaner shows up as garbage on screen rather than
# as a subtly shorter word list.
NOTES = [
    (
        "<div>食[た]べる</div>",
        "to eat<br>to consume",
        "たべる",
        "verb ichidan",
    ),
    (
        "<ruby>勉強<rt>べんきょう</rt></ruby>する[sound:benkyou.mp3]",
        "to study",
        "べんきょうする",
        "verb suru",
    ),
    (
        "昨日[きのう]は寒[さむ]かったです。",
        "It was cold yesterday. [past tense]",
        "きのうはさむかったです",
        "sentence",
    ),
    (
        "今日は{{c1::寒い}}ですね",
        "It's cold today, isn't it? &amp; brr",
        "きょうはさむいですね",
        "cloze",
    ),
    (
        "話してはいけません",
        "You must not speak",
        "はなしてはいけません",
        "sentence prohibition",
    ),
]

LEGACY_SCHEMA = """
CREATE TABLE col (
    id integer primary key, crt integer not null, mod integer not null,
    scm integer not null, ver integer not null, dty integer not null,
    usn integer not null, ls integer not null, conf text not null,
    models text not null, decks text not null, dconf text not null,
    tags text not null
);
CREATE TABLE notes (
    id integer primary key, guid text not null, mid integer not null,
    mod integer not null, usn integer not null, tags text not null,
    flds text not null, sfld integer not null, csum integer not null,
    flags integer not null, data text not null
);
CREATE TABLE cards (
    id integer primary key, nid integer not null, did integer not null,
    ord integer not null, mod integer not null, usn integer not null,
    type integer not null, queue integer not null, due integer not null,
    ivl integer not null, factor integer not null, reps integer not null,
    lapses integer not null, left integer not null, odue integer not null,
    odid integer not null, flags integer not null, data text not null
);
"""

MODERN_EXTRA_SCHEMA = """
CREATE TABLE decks (
    id integer primary key, name text not null collate unicase, mtime_secs
    integer not null, usn integer not null, common blob not null, kind blob not null
);
CREATE TABLE notetypes (
    id integer primary key, name text not null collate unicase, mtime_secs
    integer not null, usn integer not null, config blob not null
);
CREATE TABLE fields (
    ntid integer not null, ord integer not null, name text not null collate unicase,
    config blob not null, primary key (ntid, ord)
);
"""

FIELD_NAMES = ["Expression", "Meaning", "Reading"]
DECK_ID = 1600000000000
DECK_NAME = "Japanese::JapanoDict test"
MODEL_ID = 1400000000000


def _write_notes_and_cards(db, deck_id):
    for index, (expression, meaning, reading, tags) in enumerate(NOTES):
        note_id = 1500000000000 + index
        flds = SEP.join([expression, meaning, reading])
        db.execute(
            "INSERT INTO notes VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (note_id, f"guid{index}", MODEL_ID, 0, -1, tags, flds,
             expression, 0, 0, ""),
        )
        db.execute(
            "INSERT INTO cards VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (1700000000000 + index, note_id, deck_id, 0, 0, -1, 0, 0,
             index, 0, 0, 0, 0, 0, 0, 0, 0, ""),
        )


def build_legacy(path):
    """Schema 11: note types and decks live in JSON columns on `col`."""
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.executescript(LEGACY_SCHEMA)

    models = {
        str(MODEL_ID): {
            "id": MODEL_ID,
            "name": "Japanese (test)",
            # Written out of order on purpose: the importer sorts by `ord`,
            # because a collection that survived a field reorder in an old Anki
            # can have the array order disagree with it.
            "flds": [
                {"name": "Reading", "ord": 2},
                {"name": "Expression", "ord": 0},
                {"name": "Meaning", "ord": 1},
            ],
        }
    }
    decks = {
        "1": {"id": 1, "name": "Default"},
        str(DECK_ID): {"id": DECK_ID, "name": DECK_NAME},
    }
    db.execute(
        "INSERT INTO col VALUES (1,0,0,0,11,0,-1,0,'{}',?,?,'{}','{}')",
        (json.dumps(models), json.dumps(decks)),
    )
    _write_notes_and_cards(db, DECK_ID)
    db.commit()
    db.close()


def build_modern(path):
    """Schema 18: real tables, and `::` replaced by the unit separator."""
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    # Anki's schema-18 tables declare `collate unicase`, a collation Anki
    # registers at runtime and nothing else has. Plain sqlite3 refuses to even
    # CREATE the table without it, so a stand-in is registered here to build a
    # faithful fixture. Reading such a file back needs no collation as long as
    # nothing sorts by one of those columns — see `_readDeckNames`.
    db.create_collation(
        "unicase", lambda a, b: (a.lower() > b.lower()) - (a.lower() < b.lower())
    )
    db.executescript(LEGACY_SCHEMA)
    db.executescript(MODERN_EXTRA_SCHEMA)

    # col.decks/models are empty in schema 18 — everything moved to tables.
    db.execute("INSERT INTO col VALUES (1,0,0,0,18,0,-1,0,'{}','{}','{}','{}','{}')")
    db.execute(
        "INSERT INTO decks VALUES (?,?,0,-1,X'',X'')",
        (DECK_ID, DECK_NAME.replace("::", SEP)),
    )
    db.execute(
        "INSERT INTO notetypes VALUES (?,?,0,-1,X'')", (MODEL_ID, "Japanese (test)")
    )
    for ord_, name in enumerate(FIELD_NAMES):
        db.execute("INSERT INTO fields VALUES (?,?,?,X'')", (MODEL_ID, ord_, name))
    _write_notes_and_cards(db, DECK_ID)
    db.commit()
    db.close()


def package(apkg_path, collection_path, member_name):
    with zipfile.ZipFile(apkg_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.write(collection_path, member_name)
        zf.writestr("media", "{}")


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)

    legacy_db = os.path.join(out_dir, "_legacy.anki2")
    build_legacy(legacy_db)
    package(os.path.join(out_dir, "legacy.apkg"), legacy_db, "collection.anki2")

    modern_db = os.path.join(out_dir, "_modern.anki2")
    build_modern(modern_db)
    package(os.path.join(out_dir, "modern.apkg"), modern_db, "collection.anki21")

    # Contents don't matter: the importer must refuse on the member name alone,
    # before it ever tries to open anything.
    with zipfile.ZipFile(
        os.path.join(out_dir, "newformat.apkg"), "w", zipfile.ZIP_DEFLATED
    ) as zf:
        zf.writestr("collection.anki21b", b"\x28\xb5\x2f\xfd not really zstd")
        zf.writestr("meta", b"")

    # The text-export fallback, in the shape Anki 2.1.55+ writes it.
    with open(os.path.join(out_dir, "export.txt"), "w", encoding="utf-8") as f:
        f.write("#separator:tab\n#html:true\n#deck column:1\n#tags column:4\n")
        for expression, meaning, reading, tags in NOTES:
            f.write(f"{DECK_NAME}\t{expression}\t{meaning}\t{tags}\n")

    for name in (legacy_db, modern_db):
        os.remove(name)

    print(f"Wrote fixtures to {out_dir}:")
    for name in sorted(os.listdir(out_dir)):
        print(f"  {name}")


if __name__ == "__main__":
    main()

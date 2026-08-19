#!/usr/bin/env python3
"""
Fill `dictionary.freq` — a corpus frequency rank — from wordfreq
(https://github.com/rspeer/wordfreq).

WHY THIS EXISTS: nothing else in the schema ranks one common word above
another. `is_common` is a flag set on 33k rows, `score` is 200 for 22.5k rows,
and `tags` is empty for all 296k. So a search for "happy" arrived with ~226
hits tied on every available key and fell back to table order, opening on 慶事
"happy event" while 楽しい and 嬉しい didn't make the list. This column is the
tiebreaker that ranks them.

This deliberately does NOT rebuild the dictionary tables — same rule as
build_kanji_db.py. It adds the column if missing and rewrites only that
column, so re-ranking doesn't mean re-importing 296k entries.

Usage:
    pip install wordfreq
    python3 scripts/build_freq_db.py assets/databases/jitendex.db

Remember to bump `DatabaseService._dbVersion` afterwards, or existing installs
keep querying their old copy with no frequency data.

WHY NOT JMdict's OWN FREQUENCY DATA: JMdict ships `nfXX` priority tags — a
real corpus ranking, already licensed, no new source. They were tried first
and they are the *wrong corpus*: they come from a Mainichi Shimbun newspaper
wordlist, where 慶事 "happy event" is ranked (nf32) and 嬉しい "happy" is not
ranked at all. Ranking by nf made the motivating case worse, not better.
wordfreq's Japanese blend is Wikipedia, OpenSubtitles, OSCAR web text, Twitter
and Reddit — everyday language, which is what a learner is looking up.

wordfreq's code is Apache-2.0; its data files are redistributable under
CC BY-SA 4.0, the same licence as KANJIDIC2. This script's output is a
derivative of that data, so the attribution in credits_screen.dart is a
licence obligation, not decoration.
"""

import os
import sqlite3
import sys

try:
    import wordfreq
except ImportError:
    print("error: wordfreq is not installed — run `pip install wordfreq`")
    sys.exit(1)


def frequency_by_sequence(rows, freqs):
    """Map JMdict sequence -> best corpus frequency of any of its spellings.

    Frequency is resolved at **sequence level**, matching how `is_common` and
    `jlpt` are applied (see build_dictionary_db.py): a word is as common as
    its commonest spelling, so the rare spelling 發條 inherits ばね's rank
    rather than being ranked as the near-zero string it is on its own.

    Only `term` is looked up, never `reading`. A reading is shared by every
    homophone in the language — looking up はし would hand 箸, 橋 and 端 one
    another's frequency, and the whole point of the column is telling similar
    entries apart.
    """
    best = {}
    for sequence, term in rows:
        if sequence is None:
            continue
        f = freqs.get(term)
        if f:
            best[sequence] = max(best.get(sequence, 0.0), f)
    return best


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    db_path = sys.argv[1]

    if not os.path.exists(db_path):
        print(f"error: {db_path} does not exist — build the dictionary first")
        sys.exit(1)

    print("Loading wordfreq's Japanese wordlist ...")
    # get_frequency_dict rather than zipf_frequency/word_frequency: those
    # tokenise their argument and so drag in MeCab, which this script has no
    # need for. Every lookup here is a whole dictionary headword.
    freqs = wordfreq.get_frequency_dict('ja')
    print(f"  {len(freqs):,} Japanese tokens")

    conn = sqlite3.connect(db_path)
    cur = conn.cursor()

    columns = {row[1] for row in cur.execute("PRAGMA table_info(dictionary)")}
    if 'freq' not in columns:
        print("Adding dictionary.freq ...")
        cur.execute("ALTER TABLE dictionary ADD COLUMN freq INTEGER")

    rows = cur.execute("SELECT sequence, term FROM dictionary").fetchall()
    print(f"  {len(rows):,} dictionary rows")

    best = frequency_by_sequence(rows, freqs)
    sequences = {r[0] for r in rows if r[0] is not None}
    print(f"  {len(best):,} of {len(sequences):,} sequences have a frequency "
          f"({100 * len(best) / len(sequences):.1f}%)")

    # Stored as a **rank**, 1 = most frequent, NULL = not in the corpus — the
    # same shape as KANJIDIC2's `kanji.freq`, so both sort with the identical
    # `freq IS NULL, freq ASC` idiom. A rank also survives a wordfreq release
    # rescaling its absolute figures.
    ordered = sorted(best.items(), key=lambda kv: -kv[1])
    ranked = [(sequence, rank) for rank, (sequence, _) in enumerate(ordered, 1)]

    # Staged through a temp table rather than one UPDATE per sequence:
    # `dictionary` has no index on `sequence`, so 62k statements matching on it
    # would be 62k full scans of 296k rows. This is one scan with an indexed
    # lookup per row instead.
    cur.execute("CREATE TEMP TABLE freq_rank (sequence INTEGER PRIMARY KEY, "
                "rank INTEGER NOT NULL)")
    cur.executemany("INSERT INTO freq_rank(sequence, rank) VALUES (?,?)", ranked)
    cur.execute("""
        UPDATE dictionary SET freq = (
            SELECT rank FROM freq_rank WHERE freq_rank.sequence = dictionary.sequence
        )
    """)
    cur.execute("DROP TABLE freq_rank")
    conn.commit()

    covered = cur.execute(
        "SELECT COUNT(*) FROM dictionary WHERE freq IS NOT NULL").fetchone()[0]
    common_covered = cur.execute(
        "SELECT COUNT(*) FROM dictionary WHERE is_common = 1 AND freq IS NOT NULL"
    ).fetchone()[0]
    common = cur.execute(
        "SELECT COUNT(*) FROM dictionary WHERE is_common = 1").fetchone()[0]
    print(f"✓ dictionary.freq: {covered:,} rows ranked")
    print(f"  common words covered: {common_covered:,}/{common:,} "
          f"({100 * common_covered / common:.1f}%)")

    # Sanity check on the ordering itself — if a wordfreq release ever ships a
    # broken Japanese list, this is what shows it. 楽しい must outrank 慶事.
    for term in ('車', '楽しい', '嬉しい', 'めでたい', '慶事'):
        rank = cur.execute(
            "SELECT freq FROM dictionary WHERE term = ? AND freq IS NOT NULL "
            "LIMIT 1", (term,)).fetchone()
        print(f"  {term}: rank {rank[0] if rank else '—'}")

    cur.execute("VACUUM")
    conn.close()
    print("Remember to bump DatabaseService._dbVersion.")


if __name__ == "__main__":
    main()

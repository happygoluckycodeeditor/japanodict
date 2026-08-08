/// Reduces an inflected Japanese word back to the dictionary forms it could
/// have come from — 食べました → 食べる, 寒くなかった → 寒い, 読まされて → 読む.
///
/// This exists because OCR'd text is running prose, but `dictionary.term`
/// only ever holds dictionary forms. Without deinflection a scanned
/// 「今日は寒いですね」 finds nothing at all for 寒い.
///
/// The approach is Yomitan's, not a morphological analyser's: a table of
/// suffix-rewrite rules is applied breadth-first, each step recording which
/// word classes the *result* would have to belong to for the step to be
/// valid. That produces a handful of candidate dictionary forms, each with a
/// class constraint; the caller looks each one up and keeps only those whose
/// `parts_of_speech` agrees (see [rulesForPartsOfSpeech]). So 話される
/// proposes 話す (5-dan) and the lookup confirms it, while the same rules
/// proposing 話る (a 1-dan reading of the same string) find nothing and drop
/// out. No bundled analyser, no extra asset — the dictionary itself is the
/// disambiguator.
///
/// Deliberately *not* a full analyser: it does not segment sentences, handle
/// classical conjugation (JMdict's 4-dan/2-dan/nu-verb tags), or know about
/// particles. The scanner in `jp_text.dart` covers the last one by simply
/// trying shorter substrings.
library;

/// Word classes a deinflected form may belong to, as a bitmask.
///
/// These mirror the verb/adjective conjugation classes, *not* JMdict's full
/// part-of-speech list — transitivity, "noun", "exp" and friends are
/// irrelevant to how a word conjugates and are ignored.
class WordClass {
  WordClass._();

  /// No constraint: either the form hasn't been narrowed yet (the raw input)
  /// or the rule applies to anything. Rules never *narrow* to this by
  /// accident — an auxiliary like ～ている sets it on purpose, because what
  /// precedes the て can be any conjugating word.
  static const int any = 0;

  /// 一段 — 食べる, 見る.
  static const int ichidan = 1 << 0;

  /// 五段 — 話す, 読む, 買う. The row (す/む/う…) is implied by the
  /// dictionary form's last kana, which is why one flag covers all of them.
  static const int godan = 1 << 1;

  /// する and every noun+する compound (勉強する).
  static const int suru = 1 << 2;

  /// 来る / 來る / くる.
  static const int kuru = 1 << 3;

  /// ずる verbs — 信ずる, 命ずる.
  static const int zuru = 1 << 4;

  /// い-adjectives — 寒い. Also carried by the inflectional tails that are
  /// themselves い-adjectives (ない, たい), which is what lets
  /// 食べたくなかった unwind through three steps.
  static const int adjI = 1 << 5;

  /// な-adjectives — 静か. Stored bare in the dictionary (there is no 静かな
  /// row), so the attributive な and adverbial に have to be stripped before
  /// anything is found.
  static const int adjNa = 1 << 6;
}

/// One candidate dictionary form produced by [Deinflector.deinflect].
class Deinflection {
  const Deinflection({
    required this.term,
    required this.rules,
    required this.reasons,
  });

  /// The candidate dictionary form, e.g. 食べる.
  final String term;

  /// Bitmask of [WordClass] values the candidate must belong to for this
  /// derivation to hold, or [WordClass.any] when unconstrained.
  final int rules;

  /// Inflections removed, innermost last — 食べさせられました gives
  /// `['polite', 'causative-passive']`. Shown in the UI so the user can see
  /// *why* a scanned word maps to the entry it does.
  final List<String> reasons;

  /// True if a dictionary entry whose class bitmask is [entryRules] could
  /// conjugate into this deinflection.
  bool acceptsEntry(int entryRules) {
    if (rules == WordClass.any) return true;
    // An entry with no recognised conjugation class (a plain noun) can only
    // match when nothing was stripped — otherwise 猫 would "match" 猫った.
    if (entryRules == WordClass.any) return reasons.isEmpty;
    return (rules & entryRules) != 0;
  }

  @override
  String toString() => '$term (${reasons.join(' < ')})';
}

class Deinflector {
  Deinflector._();

  /// Stops runaway chains. Real Japanese rarely stacks more than about four
  /// inflections (見せられたくなかった is five and already contrived).
  static const int _maxDepth = 6;

  /// Ceiling on candidates explored per call. Reached only by pathological
  /// input; a normal word settles in well under 100.
  static const int _maxCandidates = 400;

  /// Returns every dictionary form [source] could reduce to, including
  /// [source] itself (uninflected words must still look themselves up).
  ///
  /// Candidates are unvalidated by design — many are nonsense that no
  /// dictionary lookup will confirm. Filtering happens at lookup time via
  /// [Deinflection.acceptsEntry].
  static List<Deinflection> deinflect(String source) {
    final results = <Deinflection>[
      Deinflection(term: source, rules: WordClass.any, reasons: const []),
    ];
    final seen = <String>{'$source:${WordClass.any}'};

    // Breadth-first over a growing list: each candidate is itself re-fed to
    // the rules, so 食べさせられました peels one layer per pass.
    for (var i = 0; i < results.length && results.length < _maxCandidates; i++) {
      final current = results[i];
      if (current.reasons.length >= _maxDepth) continue;

      for (final rule in _rules) {
        // The class the previous step demanded has to be one this rule can
        // produce. This is the whole disambiguation mechanism: it stops
        // 見られた unwinding as though 見る were 五段.
        if (rule.rulesIn != WordClass.any &&
            current.rules != WordClass.any &&
            (current.rules & rule.rulesIn) == 0) {
          continue;
        }

        if (rule.from.isEmpty) {
          // Bare-stem rules (連用形: 食べ → 食べる) match every string, so
          // they'd otherwise re-fire forever, stacking 食べるる. A stem is
          // only ever the outermost layer, so allow them on raw input only.
          if (current.reasons.isNotEmpty) continue;
        } else {
          if (!current.term.endsWith(rule.from)) continue;
          // A rule *may* consume the whole word — した → する and された →
          // する both depend on it, and refusing would silently break every
          // bare する form. The junk it also admits (「ます」 → 「る」) costs
          // one lookup that finds nothing.
        }

        final stem =
            current.term.substring(0, current.term.length - rule.from.length);
        final term = stem + rule.to;
        if (term == current.term || term.isEmpty) continue;

        if (!seen.add('$term:${rule.rulesOut}')) continue;
        results.add(Deinflection(
          term: term,
          rules: rule.rulesOut,
          reasons: [...current.reasons, rule.reason],
        ));
      }
    }

    return results;
  }

  /// Maps a `dictionary.parts_of_speech` cell onto a [WordClass] bitmask.
  ///
  /// The labels are the ones `build_dictionary_db.py` writes (`1-dan`,
  /// `5-dan (irreg.)`, `suru`, …), not JMdict's raw `v5k`/`vs-i` codes — the
  /// importer expands them. Classical classes (4-dan, 2-dan, nu-verb,
  /// ri-verb, shiku) are intentionally unmapped: nothing here conjugates
  /// them, so claiming a match would be worse than missing one.
  static int rulesForPartsOfSpeech(String? partsOfSpeech) {
    if (partsOfSpeech == null || partsOfSpeech.isEmpty) return WordClass.any;
    var rules = WordClass.any;
    for (final raw in partsOfSpeech.split(',')) {
      final pos = raw.trim();
      if (pos.startsWith('1-dan')) {
        rules |= WordClass.ichidan;
      } else if (pos.startsWith('5-dan')) {
        rules |= WordClass.godan;
      } else if (pos == 'suru') {
        rules |= WordClass.suru;
      } else if (pos == 'kuru') {
        rules |= WordClass.kuru;
      } else if (pos == 'zuru') {
        rules |= WordClass.zuru;
      } else if (pos == 'adjective') {
        rules |= WordClass.adjI;
      } else if (pos == 'na-adj') {
        rules |= WordClass.adjNa;
      }
    }
    return rules;
  }

  // ---------------------------------------------------------------------
  // Rule table
  // ---------------------------------------------------------------------

  /// The 五段 rows: dictionary-form ending → the stems it inflects through.
  ///
  /// Every godan rule is generated from this, because the conjugation is
  /// perfectly regular *given the row* — spelling out ~150 literal suffix
  /// pairs would be the same table with more places to typo.
  ///
  /// Fields: (連用形 i-stem, 未然形 a-stem, 仮定形 e-stem, 意向形 o-stem,
  /// て-form, past).
  static const Map<String, (String, String, String, String, String, String)>
      _godanRows = {
    'う': ('い', 'わ', 'え', 'お', 'って', 'った'),
    'く': ('き', 'か', 'け', 'こ', 'いて', 'いた'),
    'ぐ': ('ぎ', 'が', 'げ', 'ご', 'いで', 'いだ'),
    'す': ('し', 'さ', 'せ', 'そ', 'して', 'した'),
    'つ': ('ち', 'た', 'て', 'と', 'って', 'った'),
    'ぬ': ('に', 'な', 'ね', 'の', 'んで', 'んだ'),
    'ぶ': ('び', 'ば', 'べ', 'ぼ', 'んで', 'んだ'),
    'む': ('み', 'ま', 'め', 'も', 'んで', 'んだ'),
    'る': ('り', 'ら', 'れ', 'ろ', 'って', 'った'),
  };

  /// Endings that attach to the 連用形 (i-stem / ます-stem) of any verb.
  /// Politeness is one closed set, so it's applied to every class uniformly
  /// rather than restated nine times.
  static const List<(String, String)> _politeSuffixes = [
    ('ます', 'polite'),
    ('ました', 'polite past'),
    ('ません', 'polite negative'),
    ('ませんでした', 'polite past negative'),
    ('ましょう', 'polite volitional'),
    ('まして', 'polite -te'),
    ('たい', 'desiderative'),
    ('ながら', 'while'),
    ('やすい', 'easy to'),
    ('にくい', 'hard to'),
    ('すぎる', 'excessive'),
  ];

  static final List<_Rule> _rules = _buildRules();

  static List<_Rule> _buildRules() {
    final rules = <_Rule>[];

    void add(String reason, String from, String to, int rulesIn, int rulesOut) {
      rules.add(_Rule(reason, from, to, rulesIn, rulesOut));
    }

    // --- 五段 -----------------------------------------------------------
    for (final entry in _godanRows.entries) {
      final dict = entry.key;
      final (iStem, aStem, eStem, oStem, te, ta) = entry.value;
      const g = WordClass.godan;

      for (final (suffix, reason) in _politeSuffixes) {
        // たい/やすい/にくい/すぎる are themselves conjugating words, so the
        // result of stripping them still has to be reachable — hence the
        // adjI/ichidan constraint on the way in.
        final inClass = _auxiliaryClass(suffix);
        add(reason, '$iStem$suffix', dict, inClass, g);
      }
      add('masu stem', iStem, dict, WordClass.any, g);

      add('negative', '$aStemない', dict, WordClass.adjI, g);
      add('negative', '$aStemず', dict, WordClass.any, g);
      add('negative', '$aStemぬ', dict, WordClass.any, g);
      add('passive', '$aStemれる', dict, WordClass.ichidan, g);
      add('causative', '$aStemせる', dict, WordClass.ichidan, g);
      add('causative', '$aStemす', dict, WordClass.godan, g);
      add('causative-passive', '$aStemされる', dict, WordClass.ichidan, g);
      add('causative-passive', '$aStemせられる', dict, WordClass.ichidan, g);

      add('potential', '$eStemる', dict, WordClass.ichidan, g);
      add('imperative', eStem, dict, WordClass.any, g);
      add('conditional', '$eStemば', dict, WordClass.any, g);

      add('volitional', '$oStemう', dict, WordClass.any, g);

      add('-te', te, dict, WordClass.any, g);
      add('past', ta, dict, WordClass.any, g);
    }

    // 行く is the one 五段 verb whose て/た form is irregular (行って, not
    // 行いて), and it is far too common in scanned text to leave out.
    for (final stem in ['行', 'い', 'ゆ']) {
      add('-te', '$stemって', '$stemく', WordClass.any, WordClass.godan);
      add('past', '$stemった', '$stemく', WordClass.any, WordClass.godan);
    }

    // --- 一段 -----------------------------------------------------------
    const v1 = WordClass.ichidan;
    for (final (suffix, reason) in _politeSuffixes) {
      add(reason, suffix, 'る', _auxiliaryClass(suffix), v1);
    }
    // Bare 連用形 (食べ). `from` is empty, so this only fires on raw input —
    // see the guard in [deinflect].
    add('masu stem', '', 'る', WordClass.any, v1);

    add('negative', 'ない', 'る', WordClass.adjI, v1);
    add('negative', 'ず', 'る', WordClass.any, v1);
    add('negative', 'ぬ', 'る', WordClass.any, v1);
    add('passive', 'られる', 'る', WordClass.ichidan, v1);
    add('potential', 'られる', 'る', WordClass.ichidan, v1);
    // ら抜き言葉 — 食べれる. Non-standard but ubiquitous in signage and manga,
    // which is exactly the text this feature points a camera at.
    add('potential', 'れる', 'る', WordClass.ichidan, v1);
    add('causative', 'させる', 'る', WordClass.ichidan, v1);
    add('causative-passive', 'させられる', 'る', WordClass.ichidan, v1);
    add('imperative', 'ろ', 'る', WordClass.any, v1);
    add('imperative', 'よ', 'る', WordClass.any, v1);
    add('volitional', 'よう', 'る', WordClass.any, v1);
    add('conditional', 'れば', 'る', WordClass.any, v1);
    add('-te', 'て', 'る', WordClass.any, v1);
    add('past', 'た', 'る', WordClass.any, v1);

    // --- する ------------------------------------------------------------
    const vs = WordClass.suru;
    for (final (suffix, reason) in _politeSuffixes) {
      add(reason, 'し$suffix', 'する', _auxiliaryClass(suffix), vs);
    }
    add('masu stem', 'し', 'する', WordClass.any, vs);
    add('negative', 'しない', 'する', WordClass.adjI, vs);
    add('negative', 'せず', 'する', WordClass.any, vs);
    add('negative', 'せぬ', 'する', WordClass.any, vs);
    add('passive', 'される', 'する', WordClass.ichidan, vs);
    add('causative', 'させる', 'する', WordClass.ichidan, vs);
    add('causative', 'さす', 'する', WordClass.godan, vs);
    add('causative-passive', 'させられる', 'する', WordClass.ichidan, vs);
    add('potential', 'できる', 'する', WordClass.ichidan, vs);
    add('imperative', 'しろ', 'する', WordClass.any, vs);
    add('imperative', 'せよ', 'する', WordClass.any, vs);
    add('volitional', 'しよう', 'する', WordClass.any, vs);
    add('conditional', 'すれば', 'する', WordClass.any, vs);
    add('-te', 'して', 'する', WordClass.any, vs);
    add('past', 'した', 'する', WordClass.any, vs);

    // --- 来る ------------------------------------------------------------
    // Both the kana spelling and the kanji one, because 来 absorbs all three
    // stems (き/こ/く) and scanned text is overwhelmingly kanji: 来ます, 来た,
    // 来ない all have to reduce to the 来る the dictionary actually holds.
    const vk = WordClass.kuru;
    for (final k in ['来', '來']) {
      for (final (suffix, reason) in _politeSuffixes) {
        add(reason, '$k$suffix', '$kる', _auxiliaryClass(suffix), vk);
      }
      add('masu stem', k, '$kる', WordClass.any, vk);
      add('negative', '$kない', '$kる', WordClass.adjI, vk);
      add('passive', '$kられる', '$kる', WordClass.ichidan, vk);
      add('potential', '$kられる', '$kる', WordClass.ichidan, vk);
      add('causative', '$kさせる', '$kる', WordClass.ichidan, vk);
      add('imperative', '$kい', '$kる', WordClass.any, vk);
      add('volitional', '$kよう', '$kる', WordClass.any, vk);
      add('conditional', '$kれば', '$kる', WordClass.any, vk);
      add('-te', '$kて', '$kる', WordClass.any, vk);
      add('past', '$kた', '$kる', WordClass.any, vk);
    }
    for (final (suffix, reason) in _politeSuffixes) {
      add(reason, 'き$suffix', 'くる', _auxiliaryClass(suffix), vk);
    }
    add('negative', 'こない', 'くる', WordClass.adjI, vk);
    add('passive', 'こられる', 'くる', WordClass.ichidan, vk);
    add('causative', 'こさせる', 'くる', WordClass.ichidan, vk);
    add('imperative', 'こい', 'くる', WordClass.any, vk);
    add('volitional', 'こよう', 'くる', WordClass.any, vk);
    add('conditional', 'くれば', 'くる', WordClass.any, vk);
    add('-te', 'きて', 'くる', WordClass.any, vk);
    add('past', 'きた', 'くる', WordClass.any, vk);

    // --- ずる ------------------------------------------------------------
    const vz = WordClass.zuru;
    add('negative', 'じない', 'ずる', WordClass.adjI, vz);
    add('passive', 'ぜられる', 'ずる', WordClass.ichidan, vz);
    add('-te', 'じて', 'ずる', WordClass.any, vz);
    add('past', 'じた', 'ずる', WordClass.any, vz);
    for (final (suffix, reason) in _politeSuffixes) {
      add(reason, 'じ$suffix', 'ずる', _auxiliaryClass(suffix), vz);
    }

    // --- い-adjectives ----------------------------------------------------
    const adj = WordClass.adjI;
    add('past', 'かった', 'い', WordClass.any, adj);
    add('negative', 'くない', 'い', WordClass.adjI, adj);
    add('adverbial', 'く', 'い', WordClass.any, adj);
    add('-te', 'くて', 'い', WordClass.any, adj);
    add('conditional', 'ければ', 'い', WordClass.any, adj);
    add('noun form', 'さ', 'い', WordClass.any, adj);
    add('appearance', 'そう', 'い', WordClass.any, adj);
    add('excessive', 'すぎる', 'い', WordClass.ichidan, adj);
    // 良い/いい is suppletive: いくない is not a word, よくない is, and both
    // spellings appear in the dictionary.
    add('negative', 'よくない', 'いい', WordClass.adjI, adj);
    add('past', 'よかった', 'いい', WordClass.any, adj);

    // --- な-adjectives ----------------------------------------------------
    // 静かな and 静かに are not entries; 静か is. Stripping the tail is the
    // only way the scanner ever reaches the word.
    const adjNa = WordClass.adjNa;
    add('attributive', 'な', '', WordClass.adjNa, adjNa);
    add('adverbial', 'に', '', WordClass.adjNa, adjNa);
    add('copula', 'だ', '', WordClass.adjNa, adjNa);

    // --- noun + する ------------------------------------------------------
    // The dictionary stores 勉強 tagged `suru`, never 勉強する, so the last
    // step of every noun-verb reduction has to drop the する as well. The
    // rulesIn/rulesOut pair keeps it from firing on 走る-style verbs whose
    // dictionary form merely ends in る.
    add('suru noun', 'する', '', WordClass.suru, WordClass.suru);

    // --- auxiliaries that chain onto a て-form ----------------------------
    // These emit WordClass.any because whatever precedes the て can be any
    // conjugating class — the て rules above take it from there. That two-step
    // chain is what unwinds 食べてしまいました in one pass each.
    for (final (t, d) in [('て', 'で')]) {
      for (final form in [t, d]) {
        add('progressive', '$formいる', form, WordClass.any, WordClass.any);
        add('progressive', '$formいます', form, WordClass.any, WordClass.any);
        add('progressive', '$formいた', form, WordClass.any, WordClass.any);
        add('progressive', '$formる', form, WordClass.any, WordClass.any);
        add('progressive', '$formます', form, WordClass.any, WordClass.any);
        add('progressive', '$formた', form, WordClass.any, WordClass.any);
        add('resultative', '$formある', form, WordClass.any, WordClass.any);
        add('preparatory', '$formおく', form, WordClass.any, WordClass.any);
        add('completive', '$formしまう', form, WordClass.any, WordClass.any);
        add('request', '$formください', form, WordClass.any, WordClass.any);
        add('permission', '$formもいい', form, WordClass.any, WordClass.any);
        // Prohibition, every variant spelled out rather than derived:
        // 〜てはいけません is what prohibition signs actually say, and this is
        // an app you point at signs. Without it 話してはいけません splits into
        // 話して plus a spurious 廃家 ("deserted house") for the leftover はいけ.
        add('prohibition', '$formはいけない', form, WordClass.any, WordClass.any);
        add('prohibition', '$formはいけません', form, WordClass.any, WordClass.any);
        add('prohibition', '$formはならない', form, WordClass.any, WordClass.any);
        add('prohibition', '$formはなりません', form, WordClass.any, WordClass.any);
        add('prohibition', '$formはだめ', form, WordClass.any, WordClass.any);
      }
    }
    // ちゃう/じゃう are the spoken contraction of てしまう/でしまう.
    add('completive', 'ちゃう', 'て', WordClass.any, WordClass.any);
    add('completive', 'じゃう', 'で', WordClass.any, WordClass.any);
    add('completive', 'ちゃった', 'て', WordClass.any, WordClass.any);
    add('completive', 'じゃった', 'で', WordClass.any, WordClass.any);

    // たら/だら sit on the past form, so they reduce to it rather than all
    // the way down — the past rules finish the job.
    add('conditional', 'たら', 'た', WordClass.any, WordClass.any);
    add('conditional', 'だら', 'だ', WordClass.any, WordClass.any);
    add('listing', 'たり', 'た', WordClass.any, WordClass.any);
    add('listing', 'だり', 'だ', WordClass.any, WordClass.any);

    // Polite copula. Not an inflection of the word itself, but 「寒いです」
    // scans as one run and would otherwise miss.
    add('polite', 'です', '', WordClass.any, WordClass.any);
    add('polite', 'でした', '', WordClass.any, WordClass.any);

    return rules;
  }

  /// The class an auxiliary demands of the form *it* produced — たい and its
  /// friends inflect as い-adjectives, すぎる as 一段. Without this, たかった
  /// couldn't chain into たい.
  static int _auxiliaryClass(String suffix) {
    switch (suffix) {
      case 'たい':
      case 'やすい':
      case 'にくい':
        return WordClass.adjI;
      case 'すぎる':
        return WordClass.ichidan;
      default:
        return WordClass.any;
    }
  }
}

class _Rule {
  const _Rule(this.reason, this.from, this.to, this.rulesIn, this.rulesOut);

  final String reason;

  /// Suffix stripped from the inflected form. Empty means "matches any
  /// string" and is reserved for bare 連用形 stems.
  final String from;

  /// Suffix appended in its place to form the candidate.
  final String to;

  /// Class the *inflected* form must already be constrained to, or
  /// [WordClass.any] to accept anything.
  final int rulesIn;

  /// Class the candidate is constrained to after this step.
  final int rulesOut;
}

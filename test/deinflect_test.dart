import 'package:flutter_test/flutter_test.dart';
import 'package:japanodict/utils/deinflect.dart';

/// Asserts that [source] proposes [expected] as a dictionary form, and that a
/// real entry of class [entryClass] would be accepted for it.
///
/// Both halves matter: proposing 話す is useless if the class constraint then
/// rejects the 5-dan entry, and accepting everything would mean the candidate
/// list is unfiltered noise.
void expectReduces(String source, String expected, int entryClass,
    {List<String>? reasons}) {
  final candidates = Deinflector.deinflect(source);
  final match = candidates.where(
    (c) => c.term == expected && c.acceptsEntry(entryClass),
  );
  expect(
    match,
    isNotEmpty,
    reason: '$source should reduce to $expected; got '
        '${candidates.map((c) => c.term).toSet().join(', ')}',
  );
  if (reasons != null) {
    expect(match.map((c) => c.reasons), contains(reasons));
  }
}

void main() {
  group('godan', () {
    test('polite and plain forms', () {
      expectReduces('話します', '話す', WordClass.godan);
      expectReduces('話しました', '話す', WordClass.godan);
      expectReduces('話しませんでした', '話す', WordClass.godan);
      expectReduces('読まない', '読む', WordClass.godan);
      expectReduces('泳いだ', '泳ぐ', WordClass.godan);
      expectReduces('死んで', '死ぬ', WordClass.godan);
    });

    test('the three ways to spell a って te-form', () {
      // 買う, 待つ and 取る all produce って — the rules propose all three
      // dictionary forms and only the lookup can tell them apart.
      expectReduces('買って', '買う', WordClass.godan);
      expectReduces('待って', '待つ', WordClass.godan);
      expectReduces('取って', '取る', WordClass.godan);
    });

    test('voice', () {
      expectReduces('話される', '話す', WordClass.godan);
      expectReduces('読ませる', '読む', WordClass.godan);
      expectReduces('読まされる', '読む', WordClass.godan);
      expectReduces('書ける', '書く', WordClass.godan);
      expectReduces('書けば', '書く', WordClass.godan);
      expectReduces('書こう', '書く', WordClass.godan);
    });

    test('行く has an irregular te-form', () {
      expectReduces('行って', '行く', WordClass.godan);
      expectReduces('行った', '行く', WordClass.godan);
    });
  });

  group('ichidan', () {
    test('plain and polite', () {
      expectReduces('食べます', '食べる', WordClass.ichidan);
      expectReduces('食べました', '食べる', WordClass.ichidan);
      expectReduces('食べない', '食べる', WordClass.ichidan);
      expectReduces('食べて', '食べる', WordClass.ichidan);
      expectReduces('食べた', '食べる', WordClass.ichidan);
      expectReduces('食べろ', '食べる', WordClass.ichidan);
      expectReduces('食べよう', '食べる', WordClass.ichidan);
    });

    test('られる is both passive and potential', () {
      expectReduces('見られる', '見る', WordClass.ichidan);
      // ら抜き — non-standard, but it is what signage and manga actually use.
      expectReduces('見れる', '見る', WordClass.ichidan);
    });

    test('stacked inflections unwind', () {
      expectReduces('食べさせられました', '食べる', WordClass.ichidan);
      expectReduces('食べたくなかった', '食べる', WordClass.ichidan);
      expectReduces('食べてしまいました', '食べる', WordClass.ichidan);
      expectReduces('食べています', '食べる', WordClass.ichidan);
      expectReduces('食べちゃった', '食べる', WordClass.ichidan);
    });
  });

  group('irregular verbs', () {
    test('する and noun+する', () {
      expectReduces('します', 'する', WordClass.suru);
      expectReduces('勉強しています', '勉強する', WordClass.suru);
      expectReduces('された', 'する', WordClass.suru);
      expectReduces('紹介された', '紹介する', WordClass.suru);
      expectReduces('しろ', 'する', WordClass.suru);
    });

    test('来る in kanji, which hides all three stems', () {
      expectReduces('来ます', '来る', WordClass.kuru);
      expectReduces('来ない', '来る', WordClass.kuru);
      expectReduces('来た', '来る', WordClass.kuru);
      expectReduces('来て', '来る', WordClass.kuru);
      expectReduces('きました', 'くる', WordClass.kuru);
    });
  });

  group('what the dictionary does not store', () {
    // These three reductions exist because of how jitendex.db is shaped, not
    // because of Japanese grammar — the dictionary has no 勉強する row and no
    // 静かな row, so a purely morphological deinflector would find nothing.
    test('noun+する reduces past する to the bare noun', () {
      expectReduces('勉強しています', '勉強', WordClass.suru);
      expectReduces('勉強した', '勉強', WordClass.suru);
      expectReduces('紹介しました', '紹介', WordClass.suru);
    });

    test('な-adjectives shed their attributive tail', () {
      expectReduces('静かな', '静か', WordClass.adjNa);
      expectReduces('静かに', '静か', WordClass.adjNa);
    });

    test('prohibition is one token, not て plus rubble', () {
      // Left out, 話してはいけません splits and the stray はいけ matches 廃家.
      expectReduces('話してはいけません', '話す', WordClass.godan);
      expectReduces('入ってはいけない', '入る', WordClass.godan);
      expectReduces('飲んではいけません', '飲む', WordClass.godan);
    });
  });

  group('i-adjectives', () {
    test('inflection', () {
      expectReduces('寒かった', '寒い', WordClass.adjI);
      expectReduces('寒くない', '寒い', WordClass.adjI);
      expectReduces('寒くなかった', '寒い', WordClass.adjI);
      expectReduces('寒くて', '寒い', WordClass.adjI);
      expectReduces('寒ければ', '寒い', WordClass.adjI);
      expectReduces('寒さ', '寒い', WordClass.adjI);
    });

    test('polite copula is stripped', () {
      expectReduces('寒いです', '寒い', WordClass.adjI);
    });

    test('いい is suppletive', () {
      expectReduces('よくない', 'いい', WordClass.adjI);
      expectReduces('よかった', 'いい', WordClass.adjI);
    });
  });

  group('constraints', () {
    test('an uninflected word reduces to itself', () {
      expectReduces('猫', '猫', WordClass.any);
      expectReduces('食べる', '食べる', WordClass.ichidan);
    });

    test('a noun entry is only accepted when nothing was stripped', () {
      // Without this, the ichidan past rule turns 猫った into "猫 + past" and
      // the noun 猫 would answer for it.
      final past = Deinflector.deinflect('猫った').firstWhere(
            (c) => c.term == '猫る',
            orElse: () => const Deinflection(
                term: '', rules: WordClass.any, reasons: []),
          );
      expect(past.term, '猫る');
      expect(past.acceptsEntry(WordClass.any), isFalse);
    });

    test('class mismatch is rejected', () {
      // 食べます only reduces to 食べる *as an ichidan verb*. A godan entry
      // spelled 食べる would not conjugate that way.
      final candidates = Deinflector.deinflect('食べます')
          .where((c) => c.term == '食べる' && c.acceptsEntry(WordClass.godan));
      expect(candidates, isEmpty);
    });

    test('a rule may consume the whole word', () {
      // する's forms are shorter than the rules that strip them, so refusing
      // to consume the whole word would break every bare する form. The cost
      // is that a stray 「ます」 also proposes 「る」 — a candidate no entry
      // confirms, so it dies at lookup.
      expectReduces('した', 'する', WordClass.suru);
      expectReduces('して', 'する', WordClass.suru);
      expect(Deinflector.deinflect('ます').map((c) => c.term), contains('る'));
    });

    test('candidate count stays bounded', () {
      for (final word in ['食べさせられたくなかった', '猫', '話しております']) {
        expect(Deinflector.deinflect(word).length, lessThan(400));
      }
    });
  });

  group('parts of speech mapping', () {
    test('maps the importer\'s labels', () {
      expect(Deinflector.rulesForPartsOfSpeech('1-dan, transitive'),
          WordClass.ichidan);
      expect(Deinflector.rulesForPartsOfSpeech('5-dan (spec.), intransitive'),
          WordClass.godan);
      expect(Deinflector.rulesForPartsOfSpeech('adjective'), WordClass.adjI);
      expect(
        Deinflector.rulesForPartsOfSpeech('noun, suru, transitive'),
        WordClass.suru,
      );
      expect(Deinflector.rulesForPartsOfSpeech('kuru, intransitive, aux-verb'),
          WordClass.kuru);
    });

    test('classical classes are left unmapped', () {
      // 4-dan/2-dan/nu-verb conjugate by rules this file does not implement,
      // so they must not be claimed as godan.
      expect(Deinflector.rulesForPartsOfSpeech('4-dan, transitive'),
          WordClass.any);
      expect(Deinflector.rulesForPartsOfSpeech('noun'), WordClass.any);
      expect(Deinflector.rulesForPartsOfSpeech(null), WordClass.any);
    });
  });
}

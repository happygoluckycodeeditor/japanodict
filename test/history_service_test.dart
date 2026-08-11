import 'package:flutter_test/flutter_test.dart';
import 'package:japanodict/services/history_service.dart';

/// Covers [HistoryService]'s in-memory list only.
///
/// There is no sqflite/path_provider plugin under `flutter test`, so every
/// database call inside the service fails and is swallowed by its own
/// error handling — which is exactly the behaviour these tests want. The
/// ordering and prefix-collapse rules are the part worth pinning; the SQL is
/// three statements.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final history = HistoryService();
  setUp(() async => history.clear());

  test('newest search comes first', () async {
    await history.record('dragon');
    await history.record('車');
    expect(history.entries, ['車', 'dragon']);
  });

  test('re-searching an old query moves it to the top, not duplicating it',
      () async {
    await history.record('dragon');
    await history.record('車');
    await history.record('dragon');
    expect(history.entries, ['dragon', '車']);
  });

  test('typing a query one character at a time leaves a single row', () async {
    for (final prefix in ['k', 'ku', 'kur', 'kuru', 'kurum', 'kuruma']) {
      await history.record(prefix);
    }
    expect(history.entries, ['kuruma']);
  });

  test('backspacing does not downgrade the stored query', () async {
    await history.record('kuruma');
    await history.record('kurum');
    expect(history.entries, ['kuruma']);
  });

  test('a prefix of an older, non-adjacent entry is kept separate', () async {
    await history.record('kuruma');
    await history.record('dragon');
    await history.record('kuru');
    expect(history.entries, ['kuru', 'dragon', 'kuruma']);
  });

  test('blank queries are ignored', () async {
    await history.record('   ');
    await history.record('');
    expect(history.entries, isEmpty);
  });

  test('queries are trimmed', () async {
    await history.record('  dragon  ');
    expect(history.entries, ['dragon']);
  });

  test('the list is capped, dropping the oldest', () async {
    // Distinct enough that none is a prefix of another.
    for (var i = 0; i < HistoryService.maxEntries + 5; i++) {
      await history.record('query-$i-x');
    }
    expect(history.entries.length, HistoryService.maxEntries);
    expect(history.entries.first, 'query-34-x');
    expect(history.entries.last, 'query-5-x');
    expect(history.entries, isNot(contains('query-0-x')));
  });

  test('remove takes out one row and clear empties the list', () async {
    await history.record('dragon');
    await history.record('車');
    await history.remove('dragon');
    expect(history.entries, ['車']);
    await history.clear();
    expect(history.isEmpty, isTrue);
  });
}

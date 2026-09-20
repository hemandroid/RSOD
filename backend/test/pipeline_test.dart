import 'package:incident_backend/src/pipeline.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  late FakeSymbolicator symbolicator;
  late FakeAnalyzer analyzer;
  late FakeFiler filer;
  late FakeNotifier notifier;
  late FakeDedupe dedupe;
  late List<String> logs;

  IncidentPipeline build({Fingerprinter? fingerprint}) => IncidentPipeline(
        symbolicator: symbolicator,
        analyzer: analyzer,
        filer: filer,
        notifier: notifier,
        dedupe: dedupe,
        fingerprint: fingerprint ?? (_) => 'fp-1',
        log: logs.add,
      );

  setUp(() {
    symbolicator = FakeSymbolicator();
    analyzer = FakeAnalyzer();
    filer = FakeFiler();
    notifier = FakeNotifier();
    dedupe = FakeDedupe();
    logs = [];
  });

  test('a new incident is symbolicated, analysed, filed and announced',
      () async {
    await build().process(incident());

    expect(symbolicator.calls, 1);
    expect(analyzer.received.single.trace, 'SYMBOLICATED',
        reason: 'the analyser must see the decoded trace, not the raw one');
    expect(filer.filed.single.trace, 'SYMBOLICATED');
    expect(notifier.sent.single.ticket?.key, 'SCRUM-1');
    expect(notifier.sent.single.isRepeat, isFalse);
    expect(await dedupe.lookup('fp-1'), 'SCRUM-1');
  });

  test('a repeat comments on the existing ticket and files nothing new',
      () async {
    await dedupe.remember('fp-1', 'SCRUM-9');

    await build().process(incident());

    expect(filer.commented, ['SCRUM-9']);
    expect(filer.filed, isEmpty, reason: 'a repeat must not open a new ticket');
    expect(analyzer.received, isEmpty,
        reason: 're-analysing a known bug is wasted latency and tokens');
    expect(notifier.sent.single.isRepeat, isTrue);
  });

  test('failed analysis still produces a ticket', () async {
    analyzer.result = null;

    await build().process(incident());

    expect(filer.filed.single.analysis, isNull);
    expect(notifier.sent.single.ticket?.key, 'SCRUM-1');
  });

  test('failed filing still announces, and says so', () async {
    filer.result = null;

    await build().process(incident());

    final sent = notifier.sent.single;
    expect(sent.ticket, isNull);
    expect(sent.failureNote, contains('not in Jira'));
  });

  test('a fingerprint is not remembered when no ticket was created', () async {
    filer.result = null;

    await build().process(incident());

    expect(await dedupe.lookup('fp-1'), isNull,
        reason: 'remembering a failure would suppress every later retry');
  });

  test('a collaborator that throws does not stop the rest', () async {
    symbolicator.shouldThrow = true;
    analyzer.shouldThrow = true;

    await build().process(incident());

    expect(filer.filed.single.trace, 'raw trace',
        reason: 'symbolication falling over must fall back to the raw trace');
    expect(notifier.sent, hasLength(1));
    expect(logs.where((l) => l.contains('symbolication failed')), hasLength(1));
    expect(logs.where((l) => l.contains('analysis failed')), hasLength(1));
  });

  test('an un-fingerprintable incident still files, under its own id',
      () async {
    await build(fingerprint: (_) => throw StateError('boom')).process(
      incident(id: 'inc-77'),
    );

    expect(filer.filed, hasLength(1));
    expect(await dedupe.lookup('inc-77'), 'SCRUM-1');
  });

  test('concurrent reports of one bug file a single ticket', () async {
    // The failure this guards: five taps on the same broken button arrive as
    // one batch, all miss the dedupe lookup together, and five tickets appear
    // on the board mid-demo. Only reproducible with real concurrency.
    final pipeline = build();
    await Future.wait([
      for (var i = 0; i < 5; i++) pipeline.process(incident(id: 'inc-$i')),
    ]);

    expect(filer.filed, hasLength(1), reason: 'one ticket for one bug');
    expect(filer.commented, hasLength(4), reason: 'the rest are comments');
    expect(notifier.sent.where((s) => s.isRepeat), hasLength(4));
  });

  test('unrelated bugs are not serialised behind each other', () async {
    final pipeline = build(fingerprint: (i) => i.id);
    await Future.wait([
      for (var i = 0; i < 3; i++) pipeline.process(incident(id: 'bug-$i')),
    ]);

    expect(filer.filed, hasLength(3));
    expect(filer.commented, isEmpty);
  });

  test('a notifier that throws does not escape process()', () async {
    notifier.shouldThrow = true;

    await expectLater(build().process(incident()), completes);
    expect(logs.where((l) => l.contains('slack failed')), hasLength(1));
  });
}

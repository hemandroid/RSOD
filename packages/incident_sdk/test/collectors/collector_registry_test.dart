import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:incident_sdk/src/collectors/collector.dart';
import 'package:incident_sdk/src/incident_capture.dart';
import 'package:incident_sdk/src/incident_queue.dart';

void main() {
  test('merges every collector under its own name', () {
    final registry = buildCollectorRegistry([
      (name: 'a', collect: () => {'value': 1}),
      (name: 'b', collect: () => {'value': 2}),
    ]);

    expect(registry(), {
      'a': {'value': 1},
      'b': {'value': 2},
    });
  });

  test('a throwing collector loses only its own key', () {
    final registry = buildCollectorRegistry([
      (name: 'good', collect: () => {'ok': true}),
      (name: 'bad', collect: () => throw StateError('broken')),
      (name: 'also_good', collect: () => {'ok': true}),
    ]);

    final context = registry();

    expect(context['good'], {'ok': true});
    expect(context['also_good'], {'ok': true});
    expect(context['bad'], isA<Map>());
    expect((context['bad'] as Map)['_error'], contains('broken'));
  });

  test('two collectors sharing a name are caught in debug', () {
    expect(
      () => buildCollectorRegistry([
        (name: 'route', collect: () => {'a': 1}),
        (name: 'route', collect: () => {'b': 2}),
      ]),
      throwsA(isA<AssertionError>().having(
          (e) => e.toString(), 'message', contains('share a name'))),
      reason: 'silently overwriting one collector with another is a bug the '
          'developer must see while they still have the debugger open',
    );
  });

  test('a colliding name keeps both collectors under distinct keys', () {
    // The release half of the guard: throwing would mean a name typo takes
    // down incident reporting in production.
    final context = <String, dynamic>{'route': 1};
    expect(freeCollectorKey(context, 'route'), 'route#2');
    context['route#2'] = 2;
    expect(freeCollectorKey(context, 'route'), 'route#3');
    expect(freeCollectorKey(context, 'logs'), 'logs');
  });

  test('an empty collector list produces an empty context', () {
    expect(buildCollectorRegistry(const [])(), isEmpty);
  });

  // Acceptance: a fourth collector, defined only in this test, must reach a
  // captured Incident's context without any edit to Incident, IncidentQueue,
  // IncidentCapture, or IncidentSDK.
  test('a collector defined only in this test appears in a captured incident',
      () {
    final tmp = Directory.systemTemp.createTempSync('registry_acceptance');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final queue = IncidentQueue(dir: tmp);
    final fourthCollector = (
      name: 'battery',
      collect: () => {'level': 42, 'charging': false},
    );

    final capture = IncidentCapture(
      queue: queue,
      collectContext: buildCollectorRegistry([fourthCollector]),
    );

    capture.report(StateError('boom'), StackTrace.current);

    final incident = queue.pending().single;
    expect(incident.context['battery'], {'level': 42, 'charging': false});
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incident_sdk/src/incident.dart';
import 'package:incident_sdk/src/incident_capture.dart';
import 'package:incident_sdk/src/incident_queue.dart';

void main() {
  late Directory tmp;
  late IncidentQueue queue;
  late FlutterExceptionHandler? originalOnError;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('incident_capture_test');
    queue = IncidentQueue(dir: tmp);
    originalOnError = FlutterError.onError;
  });

  tearDown(() {
    FlutterError.onError = originalOnError;
    tmp.deleteSync(recursive: true);
  });

  test('captures a framework error into the queue', () {
    // Swallow the default presentation so the test output stays clean.
    FlutterError.onError = (_) {};
    IncidentCapture(queue: queue).install();

    FlutterError.onError!(FlutterErrorDetails(
      exception: Exception('checkout blew up'),
      stack: StackTrace.current,
      context: ErrorDescription('building CheckoutScreen'),
    ));

    final pending = queue.pending();
    expect(pending, hasLength(1));
    expect(pending.single.error, contains('checkout blew up'));
    expect(pending.single.errorContext, contains('CheckoutScreen'));
    expect(pending.single.source, IncidentSource.flutterError);
  });

  test('chains to a handler installed before us', () {
    var previousCalled = false;
    FlutterError.onError = (_) => previousCalled = true;

    IncidentCapture(queue: queue).install();
    FlutterError.onError!(FlutterErrorDetails(exception: Exception('x')));

    expect(previousCalled, isTrue,
        reason: 'we must not silently swallow another SDK\'s reporting');
    expect(queue.length, 1);
  });

  test('manual report reaches the queue', () {
    IncidentCapture(queue: queue).report(
        Exception('payment declined'), StackTrace.current,
        context: 'PaymentService');

    expect(queue.pending().single.source, IncidentSource.manual);
    expect(queue.pending().single.errorContext, 'PaymentService');
  });

  test('a recovered UI stall is its own source, not a manual report', () {
    IncidentCapture(queue: queue).reportStall(const Duration(seconds: 8));

    final incident = queue.pending().single;
    expect(incident.source, IncidentSource.uiStall,
        reason: 'a backend must not have to regex the error string to tell a '
            'freeze apart from a developer-filed ticket');
    expect(incident.context[uiStallContextKey], {'duration_ms': 8000});
    expect(incident.error, contains('8000'),
        reason: 'the human-readable ticket title still needs the number');
  });

  test('IncidentSource.uiStall survives a JSON round trip', () {
    IncidentCapture(queue: queue).reportStall(const Duration(milliseconds: 1234));
    final captured = queue.pending().single;

    final restored = Incident.fromJson(
        jsonDecode(captured.encode()) as Map<String, dynamic>);

    expect(restored.source, IncidentSource.uiStall);
    expect(restored.context[uiStallContextKey], {'duration_ms': 1234});
  });

  test('a source this build does not know reads back as manual', () {
    final json = jsonDecode(Incident(
      id: '1',
      capturedAt: DateTime.now(),
      source: IncidentSource.manual,
      error: 'e',
      stackTrace: '',
      appVersion: '1',
      commitSha: 'abc',
      platform: 'android',
    ).encode()) as Map<String, dynamic>;
    json['source'] = 'somethingInventedLater';

    expect(Incident.fromJson(json).source, IncidentSource.manual,
        reason: 'an unreadable source must not lose the incident, and must '
            'not invent a hook that never fired');
  });

  test('a collector cannot overwrite the stall duration', () {
    IncidentCapture(
      queue: queue,
      collectContext: () => {uiStallContextKey: 'hijacked'},
    ).reportStall(const Duration(seconds: 3));

    expect(queue.pending().single.context[uiStallContextKey],
        {'duration_ms': 3000});
  });

  test('onIncidentQueued fires with the id of the incident just written', () {
    final ids = <String>[];
    IncidentCapture(queue: queue, onIncidentQueued: ids.add)
        .report(Exception('x'), StackTrace.current);

    expect(ids.single, queue.pending().single.id,
        reason: 'the late-arriving screenshot has to name the right incident');
  });

  test('a throwing onIncidentQueued does not cost the queued incident', () {
    IncidentCapture(
      queue: queue,
      onIncidentQueued: (_) => throw StateError('screenshot exploded'),
    ).report(Exception('x'), StackTrace.current);

    expect(queue.pending(), hasLength(1));
  });

  test('a throwing context collector does not cost us the incident', () {
    FlutterError.onError = (_) {};
    IncidentCapture(
      queue: queue,
      collectContext: () => throw StateError('collector is broken'),
    ).install();

    FlutterError.onError!(FlutterErrorDetails(exception: Exception('boom')));

    final pending = queue.pending();
    expect(pending, hasLength(1), reason: 'the incident must still be stored');
    expect(pending.single.context['_collector_error'], isTrue);
  });

  test('ids stay ordered when errors land in the same millisecond', () {
    FlutterError.onError = (_) {};
    final capture = IncidentCapture(queue: queue)..install();

    for (var i = 0; i < 5; i++) {
      capture.report(Exception('crash loop $i'), StackTrace.current);
    }

    final ids = queue.pending().map((i) => i.id).toList();
    expect(ids, equals([...ids]..sort()),
        reason: 'a crash loop must not '
            'scramble incident order');
    expect(ids.toSet(), hasLength(5), reason: 'ids must be unique');
  });
}

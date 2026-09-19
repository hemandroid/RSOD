import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incident_sdk/src/incident.dart';
import 'package:incident_sdk/src/incident_capture.dart';
import 'package:incident_sdk/src/incident_queue.dart';
import 'package:incident_sdk/src/watchdog/ui_watchdog.dart';

void main() {
  // Every test drives the watchdog through [UiWatchdog.checkNow] with this
  // fake elapsed-time clock, never through the real [Timer] and never
  // through a real sleep — a suite that actually waited out a 5s threshold
  // would be too slow to run on every commit and would not be testing
  // anything a faster clock couldn't. It is a [Duration], not a [DateTime]:
  // the watchdog's own clock seam is monotonic-only (see the "Monotonic
  // ticks only" doc on `UiWatchdog._elapsed`), so the fake has to be able to
  // stand in for one — a `DateTime`-shaped fake would let a test accidentally
  // pass and still miss a wall-clock regression.
  late Duration fakeElapsed;
  Duration elapsed() => fakeElapsed;

  /// Builds a watchdog and primes its baseline with one no-op tick, mirroring
  /// what [UiWatchdog.start] does before the first real heartbeat: the first
  /// tick only ever records a start time, it can never itself be a stall.
  UiWatchdog build({
    required void Function(Duration) onStall,
    Duration threshold = const Duration(seconds: 5),
  }) {
    final watchdog =
        UiWatchdog(onStall: onStall, threshold: threshold, elapsed: elapsed);
    watchdog.checkNow();
    return watchdog;
  }

  setUp(() {
    fakeElapsed = Duration.zero;
  });

  test('a block past the threshold reports exactly one stall, with its '
      'duration', () {
    final stalls = <Duration>[];
    final watchdog = build(onStall: stalls.add);

    fakeElapsed += const Duration(seconds: 6);
    watchdog.checkNow();

    expect(stalls, hasLength(1));
    expect(stalls.single, const Duration(seconds: 6));
  });

  test('recovery does not keep reporting: the next healthy tick is silent',
      () {
    final stalls = <Duration>[];
    final watchdog = build(onStall: stalls.add);

    fakeElapsed += const Duration(seconds: 6);
    watchdog.checkNow();
    fakeElapsed += const Duration(seconds: 1);
    watchdog.checkNow();

    expect(stalls, hasLength(1),
        reason: 'the second, healthy tick must not double-report');
  });

  test('a block shorter than the threshold reports nothing', () {
    final stalls = <Duration>[];
    final watchdog = build(onStall: stalls.add);

    fakeElapsed += const Duration(seconds: 3);
    watchdog.checkNow();

    expect(stalls, isEmpty);
  });

  test('a gap exactly at the threshold is not a stall', () {
    final stalls = <Duration>[];
    final watchdog =
        build(onStall: stalls.add, threshold: const Duration(seconds: 5));

    fakeElapsed += const Duration(seconds: 5);
    watchdog.checkNow();

    expect(stalls, isEmpty,
        reason: 'the boundary itself must not read as past it — only '
            'strictly greater than the threshold counts');
  });

  test('one tick past the threshold is a stall', () {
    // A fresh watchdog: each tick resets the baseline it measures from
    // (whether or not it reported), so this checks the boundary+1ms case
    // from a clean baseline rather than accumulating on top of the previous
    // test's exact-threshold tick.
    final stalls = <Duration>[];
    final watchdog =
        build(onStall: stalls.add, threshold: const Duration(seconds: 5));

    fakeElapsed += const Duration(seconds: 5, milliseconds: 1);
    watchdog.checkNow();

    expect(stalls, hasLength(1),
        reason: 'one millisecond past the boundary must report');
  });

  test('backgrounding the app suppresses the elapsed time, even past '
      'threshold', () {
    final stalls = <Duration>[];
    final watchdog = build(onStall: stalls.add);

    watchdog.didChangeAppLifecycleState(AppLifecycleState.paused);
    fakeElapsed += const Duration(seconds: 30);
    watchdog.checkNow();
    watchdog.didChangeAppLifecycleState(AppLifecycleState.resumed);
    fakeElapsed += const Duration(milliseconds: 200);
    watchdog.checkNow();

    expect(stalls, isEmpty,
        reason: 'a suspended app going 30s without a frame is normal, not a '
            'stall');
  });

  test('a real stall that starts right as the app resumes is still caught',
      () {
    final stalls = <Duration>[];
    final watchdog = build(onStall: stalls.add);

    watchdog.didChangeAppLifecycleState(AppLifecycleState.paused);
    fakeElapsed += const Duration(seconds: 10);
    watchdog.didChangeAppLifecycleState(AppLifecycleState.resumed);
    fakeElapsed += const Duration(seconds: 7);
    watchdog.checkNow();

    expect(stalls, hasLength(1));
    expect(stalls.single, const Duration(seconds: 7),
        reason: 'only the time since resuming counts toward the stall');
  });

  test('start and stop manage the timer and lifecycle observer without '
      'throwing, and are idempotent', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    // An interval far longer than any test run, so stop() always cancels it
    // before it can ever fire — this proves start()/stop() wiring is safe
    // without waiting on a real timer tick.
    final watchdog = UiWatchdog(
      onStall: (_) {},
      heartbeatInterval: const Duration(hours: 1),
      elapsed: elapsed,
    );

    expect(() {
      watchdog.start();
      watchdog.start();
      watchdog.stop();
      watchdog.stop();
    }, returnsNormally);
  });

  test('a measured stall reaches the queue as a uiStall incident', () {
    // The production wiring, end to end: IncidentCapture.reportStall is
    // passed straight to onStall with no adapter, so what the watchdog
    // measures is what a backend reads.
    final tmp = Directory.systemTemp.createTempSync('watchdog_wiring');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final queue = IncidentQueue(dir: tmp);
    final watchdog = build(onStall: IncidentCapture(queue: queue).reportStall);

    fakeElapsed += const Duration(seconds: 8);
    watchdog.checkNow();

    final incident = queue.pending().single;
    expect(incident.source, IncidentSource.uiStall);
    expect(incident.context[uiStallContextKey], {'duration_ms': 8000});
  });

  test('an onStall that throws does not escape the watchdog', () {
    final watchdog = build(onStall: (_) => throw StateError('boom'));

    fakeElapsed += const Duration(seconds: 6);

    expect(() => watchdog.checkNow(), returnsNormally);
  });
}

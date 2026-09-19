import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:incident_sdk/src/incident.dart';
import 'package:incident_sdk/src/incident_queue.dart';
import 'package:incident_sdk/src/upload/incident_uploader.dart';
import 'package:incident_sdk/src/upload/transport.dart';

Incident _incident(String id) => Incident(
      id: id,
      capturedAt: DateTime.utc(2026, 9, 19),
      source: IncidentSource.flutterError,
      error: 'boom',
      stackTrace: 'stack',
      appVersion: '1.0.0',
      commitSha: 'abc123',
      platform: 'android',
    );

enum _Reply { success, permanent, transient, payloadTooLarge, rateLimited }

/// Records every batch it's handed and replays [replies] in order (the last
/// entry repeats once exhausted) — no socket, no backend, per the ban on real
/// network in these tests.
class _FakeTransport implements IncidentTransport {
  final List<_Reply> replies;

  /// Used whenever the current reply is [_Reply.rateLimited], standing in
  /// for a backend-supplied `Retry-After`.
  final Duration? rateLimitRetryAfter;

  final List<List<Map<String, dynamic>>> calls = [];
  var _next = 0;

  _FakeTransport(this.replies, {this.rateLimitRetryAfter});

  @override
  Future<void> send(List<Map<String, dynamic>> incidents) async {
    calls.add(incidents);
    final reply = replies[min(_next, replies.length - 1)];
    _next++;
    switch (reply) {
      case _Reply.success:
        return;
      case _Reply.permanent:
        throw const PermanentUploadFailure('token rejected');
      case _Reply.transient:
        throw const SocketException('offline');
      case _Reply.payloadTooLarge:
        throw const PayloadTooLargeFailure();
      case _Reply.rateLimited:
        throw RateLimited(rateLimitRetryAfter);
    }
  }
}

/// Full-jitter backoff picks a delay anywhere between zero and the capped
/// value; a [Random] pinned at 1.0 makes that upper bound the actual delay,
/// so tests can assert on growth and the cap deterministically.
class _MaxJitterRandom implements Random {
  @override
  double nextDouble() => 1.0;
  @override
  bool nextBool() => true;
  @override
  int nextInt(int max) => max - 1;
}

/// Stands in for a real timer: records every delay the uploader asks to
/// wait, resolves instantly (no real sleep), and stops the loop once
/// [stopAfter] delays have been recorded so a test's background loop
/// terminates deterministically instead of spinning forever.
class _SleepRecorder {
  final int stopAfter;
  final delays = <Duration>[];
  final _done = Completer<void>();
  IncidentUploader? uploader;

  _SleepRecorder(this.stopAfter);

  Future<void> get done => _done.future;

  Future<void> call(Duration delay) async {
    delays.add(delay);
    if (delays.length >= stopAfter) {
      uploader?.stop();
      if (!_done.isCompleted) _done.complete();
    }
  }
}

void main() {
  late Directory tmp;
  late IncidentQueue queue;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('incident_uploader_test');
    queue = IncidentQueue(dir: tmp, maxPending: 50);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('successful upload removes exactly the uploaded incidents', () async {
    queue.enqueueSync(_incident('001'));
    queue.enqueueSync(_incident('002'));
    queue.enqueueSync(_incident('003'));
    final transport = _FakeTransport([_Reply.success]);
    final sleep = _SleepRecorder(1);
    final uploader = IncidentUploader(
      queue: queue,
      transport: transport,
      batchSize: 2,
      sleep: sleep.call,
    );
    sleep.uploader = uploader;

    uploader.start();
    await sleep.done;

    expect(queue.length, 0);
    expect(transport.calls, hasLength(2), reason: 'two incidents, then one');
    expect(transport.calls[0], hasLength(2));
    expect(transport.calls[1], hasLength(1));
  });

  test('a transient failure leaves the queue intact for the next attempt',
      () async {
    queue.enqueueSync(_incident('001'));
    final transport = _FakeTransport([_Reply.transient]);
    final sleep = _SleepRecorder(1);
    final uploader = IncidentUploader(
      queue: queue,
      transport: transport,
      sleep: sleep.call,
    );
    sleep.uploader = uploader;

    uploader.start();
    await sleep.done;

    expect(queue.length, 1, reason: 'nothing confirmed, nothing removed');
    expect(transport.calls, hasLength(1));
  });

  test('a transient failure stops the drain, leaving later batches queued',
      () async {
    queue.enqueueSync(_incident('001'));
    queue.enqueueSync(_incident('002'));
    queue.enqueueSync(_incident('003'));
    final transport = _FakeTransport([_Reply.success, _Reply.transient]);
    final sleep = _SleepRecorder(1);
    final uploader = IncidentUploader(
      queue: queue,
      transport: transport,
      batchSize: 1,
      sleep: sleep.call,
    );
    sleep.uploader = uploader;

    uploader.start();
    await sleep.done;

    expect(queue.pending().map((i) => i.id), ['002', '003'],
        reason: '001 was confirmed; 002 failed transiently; 003 was never '
            'attempted so the backend is not hit repeatedly in one round');
    expect(transport.calls, hasLength(2));
  });

  test('a permanent rejection discards the batch without retrying',
      () async {
    queue.enqueueSync(_incident('001'));
    final transport = _FakeTransport([_Reply.permanent]);
    final sleep = _SleepRecorder(1);
    final uploader = IncidentUploader(
      queue: queue,
      transport: transport,
      sleep: sleep.call,
    );
    sleep.uploader = uploader;

    uploader.start();
    await sleep.done;

    expect(queue.length, 0, reason: 'a rejected token will never succeed');
    expect(transport.calls, hasLength(1), reason: 'discarded, not retried');
  });

  test('backoff grows exponentially then holds at the cap', () async {
    queue.enqueueSync(_incident('001'));
    final transport = _FakeTransport([_Reply.transient]);
    final sleep = _SleepRecorder(6);
    final uploader = IncidentUploader(
      queue: queue,
      transport: transport,
      baseDelay: const Duration(seconds: 1),
      maxDelay: const Duration(seconds: 8),
      random: _MaxJitterRandom(),
      sleep: sleep.call,
    );
    sleep.uploader = uploader;

    uploader.start();
    await sleep.done;

    expect(sleep.delays, [
      const Duration(seconds: 1),
      const Duration(seconds: 2),
      const Duration(seconds: 4),
      const Duration(seconds: 8),
      const Duration(seconds: 8),
      const Duration(seconds: 8),
    ]);
  });

  test('backoff resets to the base delay after a clean drain', () async {
    queue.enqueueSync(_incident('001'));
    final transport =
        _FakeTransport([_Reply.transient, _Reply.transient, _Reply.success]);
    final sleep = _SleepRecorder(3);
    final uploader = IncidentUploader(
      queue: queue,
      transport: transport,
      baseDelay: const Duration(seconds: 1),
      maxDelay: const Duration(seconds: 30),
      random: _MaxJitterRandom(),
      sleep: sleep.call,
    );
    sleep.uploader = uploader;

    uploader.start();
    await sleep.done;

    expect(sleep.delays, [
      const Duration(seconds: 1), // 1st transient failure
      const Duration(seconds: 2), // 2nd: streak grew
      const Duration(seconds: 1), // success: back to the base delay
    ], reason: 'a streak that had grown must not carry into the next round');
  });

  test('jitter spreads the delay instead of always retrying at the cap',
      () async {
    // Five independent uploaders, each hitting one transient failure with
    // the real (unseeded) Random. If jitter were absent every delay would be
    // identical; full jitter should scatter them across [0, baseDelay].
    final observed = <Duration>{};
    for (var i = 0; i < 5; i++) {
      final localQueue =
          IncidentQueue(dir: Directory.systemTemp.createTempSync('jitter'));
      localQueue.enqueueSync(_incident('001'));
      final transport = _FakeTransport([_Reply.transient]);
      final sleep = _SleepRecorder(1);
      final uploader = IncidentUploader(
        queue: localQueue,
        transport: transport,
        baseDelay: const Duration(seconds: 10),
        sleep: sleep.call,
      );
      sleep.uploader = uploader;
      uploader.start();
      await sleep.done;
      observed.add(sleep.delays.single);
      localQueue.dir.deleteSync(recursive: true);
    }

    expect(observed.length, greaterThan(1),
        reason: 'five draws should not all land on the same delay');
    for (final d in observed) {
      expect(d, lessThanOrEqualTo(const Duration(seconds: 10)));
      expect(d, greaterThanOrEqualTo(Duration.zero));
    }
  });

  test('start is idempotent: a second call does not run a second loop',
      () async {
    queue.enqueueSync(_incident('001'));
    final transport = _FakeTransport([_Reply.success]);
    final sleep = _SleepRecorder(1);
    final uploader = IncidentUploader(
      queue: queue,
      transport: transport,
      sleep: sleep.call,
    );
    sleep.uploader = uploader;

    uploader.start();
    uploader.start();
    await sleep.done;

    expect(transport.calls, hasLength(1));
  });

  test('an empty queue is a no-op: no transport calls, still polls quietly',
      () async {
    final transport = _FakeTransport([_Reply.success]);
    final sleep = _SleepRecorder(1);
    final uploader = IncidentUploader(
      queue: queue,
      transport: transport,
      sleep: sleep.call,
    );
    sleep.uploader = uploader;

    uploader.start();
    await sleep.done;

    expect(transport.calls, isEmpty);
  });

  test(
      'a too-large batch is split and retried instead of discarding '
      'every incident in it', () async {
    for (final id in ['001', '002', '003', '004']) {
      queue.enqueueSync(_incident(id));
    }
    // 1 call for the full batch (413), then one per half once split.
    final transport =
        _FakeTransport([_Reply.payloadTooLarge, _Reply.success, _Reply.success]);
    final sleep = _SleepRecorder(1);
    final uploader = IncidentUploader(
      queue: queue,
      transport: transport,
      batchSize: 4,
      sleep: sleep.call,
    );
    sleep.uploader = uploader;

    uploader.start();
    await sleep.done;

    expect(queue.length, 0, reason: 'both halves eventually succeeded');
    expect(transport.calls, hasLength(3));
    expect(transport.calls[0], hasLength(4), reason: 'the original, too-big batch');
    expect(transport.calls[1], hasLength(2));
    expect(transport.calls[2], hasLength(2));
  });

  test(
      'a single incident that is too large on its own is discarded, not '
      'retried forever', () async {
    queue.enqueueSync(_incident('001'));
    final transport = _FakeTransport([_Reply.payloadTooLarge]);
    final sleep = _SleepRecorder(1);
    final uploader = IncidentUploader(
      queue: queue,
      transport: transport,
      sleep: sleep.call,
    );
    sleep.uploader = uploader;

    uploader.start();
    await sleep.done;

    expect(queue.length, 0);
    expect(transport.calls, hasLength(1), reason: 'splitting it further cannot help');
  });

  test('a rate limit is transient and honours the backend\'s Retry-After',
      () async {
    queue.enqueueSync(_incident('001'));
    final transport = _FakeTransport(
      [_Reply.rateLimited, _Reply.success],
      rateLimitRetryAfter: const Duration(seconds: 5),
    );
    final sleep = _SleepRecorder(1);
    final uploader = IncidentUploader(
      queue: queue,
      transport: transport,
      baseDelay: const Duration(seconds: 1),
      maxDelay: const Duration(seconds: 30),
      sleep: sleep.call,
    );
    sleep.uploader = uploader;

    uploader.start();
    await sleep.done;

    expect(sleep.delays.single, const Duration(seconds: 5),
        reason: 'the backend said 5s; our own 1s backoff must not override it');
    expect(queue.length, 1, reason: 'still queued: nothing succeeded yet');
  });

  test('a Retry-After longer than the ceiling is clamped to maxDelay',
      () async {
    queue.enqueueSync(_incident('001'));
    final transport = _FakeTransport(
      [_Reply.rateLimited],
      rateLimitRetryAfter: const Duration(minutes: 20),
    );
    final sleep = _SleepRecorder(1);
    final uploader = IncidentUploader(
      queue: queue,
      transport: transport,
      baseDelay: const Duration(seconds: 1),
      maxDelay: const Duration(seconds: 10),
      sleep: sleep.call,
    );
    sleep.uploader = uploader;

    uploader.start();
    await sleep.done;

    expect(sleep.delays.single, const Duration(seconds: 10),
        reason: 'a backend cannot make this loop sleep past its own ceiling');
  });

  test(
      'stop() then an immediate start() does not leave two loops draining '
      'the same queue', () async {
    queue.enqueueSync(_incident('001'));
    final transport = _FakeTransport([_Reply.transient, _Reply.success]);
    // A hand-controlled sleep: unlike _SleepRecorder, it does not resolve on
    // its own, so the test can hold the first loop asleep — exactly the
    // window in which the old bug let a restarted loop double up.
    final sleepGate = <Completer<void>>[];
    final uploader = IncidentUploader(
      queue: queue,
      transport: transport,
      sleep: (delay) {
        final c = Completer<void>();
        sleepGate.add(c);
        return c.future;
      },
    );

    uploader.start();
    // Let the first drain (transient failure) run and reach its sleep.
    await Future<void>.delayed(Duration.zero);
    expect(transport.calls, hasLength(1));
    expect(sleepGate, hasLength(1), reason: 'the old loop is now asleep');

    // stop() then start() again while the old loop is still asleep — the
    // exact race described in the review.
    uploader.stop();
    uploader.start();
    await Future<void>.delayed(Duration.zero);

    // Waking the OLD loop's sleep must not let it drain a second time; only
    // the new loop (started above) may have touched the transport since.
    sleepGate[0].complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(transport.calls, hasLength(2),
        reason: 'one attempt from the old loop, one from the new loop — '
            'never both racing after the restart');
    expect(queue.length, 0, reason: 'the new loop\'s attempt succeeded');
  });

  test('stop halts the loop without touching the queue', () async {
    queue.enqueueSync(_incident('001'));
    final transport = _FakeTransport([_Reply.transient]);
    final sleep = _SleepRecorder(1);
    final uploader = IncidentUploader(
      queue: queue,
      transport: transport,
      sleep: sleep.call,
    );
    sleep.uploader = uploader;

    uploader.start();
    await sleep.done;
    final callsAfterStop = transport.calls.length;
    // Give any stray continuation a chance to run; there should be none.
    await Future<void>.delayed(Duration.zero);

    expect(transport.calls.length, callsAfterStop);
    expect(queue.length, 1);
  });
}

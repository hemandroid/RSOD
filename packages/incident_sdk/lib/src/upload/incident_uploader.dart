import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../incident.dart';
import '../incident_queue.dart';
import 'transport.dart';

/// Drains [IncidentQueue] to a backend, in the background, for as long as the
/// app runs.
///
/// Nothing here is on the crash path: it is async, it batches, and it can
/// wait minutes between attempts, none of which a crash handler can afford.
/// Its only contract with the crash path is [IncidentQueue] itself — whatever
/// [IncidentQueue.enqueueSync] wrote to disk, this eventually reads with
/// [IncidentQueue.pending] and clears with [IncidentQueue.remove]. Because
/// that state lives on disk rather than in this object, an app restart loses
/// nothing: a fresh [IncidentUploader] started after relaunch just finds the
/// same pending incidents and carries on.
///
/// Offline is the expected case here, not an error: a transient failure (a
/// 5xx, a dropped connection, a device with no signal) backs off
/// exponentially with jitter, capped at [maxDelay], so a device offline for
/// hours makes one attempt and then a handful of quiet, spread-out retries —
/// never a tight loop, never a log line per failed attempt. A permanent
/// failure (a 4xx that will never succeed) discards the batch immediately
/// instead of retrying something that cannot, logging once why. Every path
/// through this class is guarded so nothing it does — not a queue error, not
/// a transport error, not a broken sleep — can ever surface as a thrown
/// exception or an unhandled Future rejection in the host app.
class IncidentUploader {
  final IncidentQueue queue;
  final IncidentTransport transport;

  /// Incidents per request. Keeps one oversized request from blocking an
  /// otherwise-healthy queue, and keeps memory bounded when a lot has queued
  /// up.
  final int batchSize;

  /// Delay before the first retry after a transient failure, and also the
  /// interval used to check again once the queue is empty or fully drained.
  final Duration baseDelay;

  /// Backoff never grows past this — the retry ceiling. Without a cap, a
  /// backend that is down for a week would end up being retried about once a
  /// week, which is worse than a bounded, regular check-in. Also the ceiling
  /// applied to a backend-supplied `Retry-After` (see [RateLimited]): a
  /// misbehaving backend does not get to make this loop sleep longer than
  /// its own worst case.
  final Duration maxDelay;

  final Random _random;

  /// The wait primitive, injected so tests can drive the loop instantly
  /// instead of waiting on real timers or pulling in a fake-async harness.
  /// Defaults to an actual delay.
  final Future<void> Function(Duration) _sleep;

  /// Identifies the currently-active loop. `start()` mints a fresh token and
  /// only the loop holding it keeps running; `stop()` clears it. This is
  /// what makes stop-then-immediate-start safe: a loop that was asleep in
  /// [_sleep] when `stop()` fired wakes up holding a token that no longer
  /// matches [_activeToken] (a new `start()` replaced it), so it exits
  /// instead of continuing alongside the loop `start()` just created. A
  /// plain boolean can't do this — it can't tell an old, still-waking loop
  /// apart from a new one, and two loops draining the same queue means
  /// concurrent double-upload.
  Object? _activeToken;

  /// Set by a [RateLimited] failure so the *next* sleep honours the
  /// backend's own `Retry-After` instead of this class's computed backoff.
  /// Consumed (and cleared) the moment it's read, so it only ever affects
  /// the one retry it was issued for.
  Duration? _retryAfterOverride;

  IncidentUploader({
    required this.queue,
    required this.transport,
    this.batchSize = 20,
    this.baseDelay = const Duration(seconds: 30),
    this.maxDelay = const Duration(minutes: 30),
    Random? random,
    Future<void> Function(Duration)? sleep,
  })  : _random = random ?? Random(),
        _sleep = sleep ?? Future.delayed;

  /// Starts the background drain loop. Idempotent: a call while one is
  /// already running does nothing, so whatever triggers this (app launch,
  /// resume from background, a connectivity callback) can call it freely
  /// without ever racing two loops against the same queue.
  void start() {
    if (_activeToken != null) return;
    final token = Object();
    _activeToken = token;
    // Deliberately not awaited: this is a background loop meant to outlive
    // the call that started it. Every path inside is wrapped so it cannot
    // throw into the caller or escape as an unhandled rejection.
    unawaited(_loop(token));
  }

  /// Stops the loop after whatever attempt is in flight finishes. Nothing
  /// queued is lost — it is still on disk, ready for the next [start].
  void stop() => _activeToken = null;

  Future<void> _loop(Object token) async {
    var failureStreak = 0;
    while (identical(_activeToken, token)) {
      bool hitTransientFailure;
      try {
        hitTransientFailure = await _drainOnce();
      } catch (_) {
        // Every call inside _drainOnce is already individually guarded, but
        // this loop is the app's entire background upload story: a surprise
        // anywhere in it must never become an unhandled Future rejection.
        // Treat it exactly like a network failure and back off.
        hitTransientFailure = true;
      }
      if (!identical(_activeToken, token)) return;

      final Duration delay;
      if (hitTransientFailure) {
        failureStreak++;
        final override = _retryAfterOverride;
        _retryAfterOverride = null;
        delay = override == null
            ? _backoff(failureStreak)
            : (override > maxDelay ? maxDelay : override);
      } else {
        // A clean drain (including an empty queue) means the backend is
        // healthy; reset so the next real failure starts from the shortest
        // delay again instead of inheriting an old streak.
        failureStreak = 0;
        delay = baseDelay;
      }
      try {
        await _sleep(delay);
      } catch (_) {
        // A broken sleep implementation must not kill this loop either.
      }
    }
  }

  /// Uploads whatever is pending right now, oldest batch first.
  ///
  /// Returns true if a transient failure cut the drain short — remaining
  /// batches are left on the queue untouched, for the next attempt. Returns
  /// false if every batch was resolved one way or another (success, a
  /// permanent discard, or there was nothing pending).
  Future<bool> _drainOnce() async {
    final List<Incident> incidents;
    try {
      incidents = queue.pending();
    } catch (_) {
      // IncidentQueue.pending is documented never to throw, but this loop is
      // the app's entire background upload story and must survive even a
      // surprise here. Treat it exactly like a network failure: back off.
      return true;
    }

    for (var start = 0; start < incidents.length; start += batchSize) {
      final batch = incidents.sublist(
        start,
        min(start + batchSize, incidents.length),
      );
      if (await _sendBatch(batch)) return true;
    }
    return false;
  }

  /// Sends one batch, splitting and retrying it on [PayloadTooLargeFailure]
  /// so a single oversized incident costs only itself rather than every
  /// batch-mate riding along with it. Returns true if the caller should stop
  /// the whole drain for this round (a transient failure, including one that
  /// carried its own `Retry-After` via [RateLimited]).
  Future<bool> _sendBatch(List<Incident> batch) async {
    try {
      await transport.send(
        batch.map((incident) => incident.toJson()).toList(growable: false),
      );
      _removeQuietly(batch);
      return false;
    } on PermanentUploadFailure catch (failure) {
      _discard(batch, failure.reason);
      return false;
    } on PayloadTooLargeFailure {
      if (batch.length == 1) {
        // No amount of splitting helps a single incident that is too large
        // on its own, and retrying it forever would wedge every incident
        // behind it. Discard it, same as any other unrecoverable rejection.
        _discard(batch, 'too large for a single request');
        return false;
      }
      final mid = batch.length ~/ 2;
      if (await _sendBatch(batch.sublist(0, mid))) return true;
      return _sendBatch(batch.sublist(mid));
    } on RateLimited catch (limited) {
      _retryAfterOverride = limited.retryAfter;
      return true;
    } catch (_) {
      // Network error, timeout, 5xx: worth retrying. Stop here instead of
      // moving to the next batch, so this one is retried first and a downed
      // backend isn't hit once per remaining batch.
      return true;
    }
  }

  /// Removes each incident from the queue independently, swallowing any
  /// failure. [IncidentQueue.remove] is documented never to throw, but this
  /// runs after upload has already been confirmed (or the batch has been
  /// deliberately discarded) — letting a disk error here escape would turn a
  /// finished upload into an unhandled exception in the host app. A single
  /// incident that fails to delete is left queued rather than lost: it is
  /// uploaded again next round, which is a harmless duplicate, not a loss.
  void _removeQuietly(List<Incident> batch) {
    for (final incident in batch) {
      try {
        queue.remove(incident.id);
      } catch (_) {
        // See doc comment: leave it queued for the next attempt.
      }
    }
  }

  void _discard(List<Incident> batch, String reason) {
    _removeQuietly(batch);
    // The one log line this class produces on the failure path: a discard is
    // a decision worth a record, unlike a transient retry, which would just
    // be six hours of noise from an offline device.
    debugPrint('incident_sdk: discarding ${batch.length} incident(s) — $reason');
  }

  /// Exponential backoff, capped at [maxDelay], with full jitter: the actual
  /// delay is chosen uniformly between zero and the capped value, so retries
  /// from many devices spread out instead of all landing at once.
  Duration _backoff(int failureStreak) {
    // Capping the exponent (not just the result) keeps the intermediate
    // value from overflowing well before failureStreak could plausibly climb
    // that high.
    final exponent = min(failureStreak - 1, 20);
    final grown = baseDelay.inMilliseconds * pow(2, exponent);
    final capped = min(grown.toDouble(), maxDelay.inMilliseconds.toDouble());
    return Duration(milliseconds: (_random.nextDouble() * capped).round());
  }
}

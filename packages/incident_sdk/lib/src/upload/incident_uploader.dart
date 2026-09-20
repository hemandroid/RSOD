import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../incident.dart';
import '../incident_queue.dart';
import 'transport.dart';

/// Drains [IncidentQueue] to a backend, in the background, for as long as
/// the app runs.
///
/// Nothing here is on the crash path — it's async and can wait minutes
/// between attempts. State lives on disk in [IncidentQueue], not in this
/// object, so an app restart loses nothing: a fresh instance just finds the
/// same pending incidents.
///
/// Offline is the expected case, not an error: a transient failure backs off
/// exponentially with jitter, capped at [maxDelay]; a permanent failure (a
/// 4xx that will never succeed) discards the batch immediately instead of
/// retrying forever. Every path is guarded so nothing here can surface as a
/// thrown exception or unhandled Future rejection in the host app.
class IncidentUploader {
  final IncidentQueue queue;
  final IncidentTransport transport;

  /// Incidents per request. Keeps one oversized request from blocking an
  /// otherwise-healthy queue.
  final int batchSize;

  /// Delay before the first retry, and the interval used once the queue is
  /// drained.
  final Duration baseDelay;

  /// Backoff never grows past this. Also caps a backend-supplied
  /// `Retry-After` (see [RateLimited]) — a misbehaving backend doesn't get
  /// to make this loop sleep longer than its own worst case.
  final Duration maxDelay;

  final Random _random;

  /// The wait primitive, injected so tests can drive the loop instantly
  /// instead of waiting on real timers.
  final Future<void> Function(Duration) _sleep;

  /// Identifies the currently-active loop; only the loop holding the current
  /// token keeps running. A plain boolean can't distinguish an old,
  /// still-waking loop (asleep in [_sleep] when `stop()` fired) from a new
  /// one started right after, which a boolean would let run concurrently and
  /// double-upload.
  Object? _activeToken;

  /// Set by a [RateLimited] failure so the *next* sleep honours the
  /// backend's `Retry-After` instead of the computed backoff. Cleared the
  /// moment it's read.
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

  /// Idempotent: a call while one is already running does nothing, so
  /// whatever triggers this can call it freely without racing two loops
  /// against the same queue.
  void start() {
    if (_activeToken != null) return;
    final token = Object();
    _activeToken = token;
    // Deliberately not awaited: a background loop meant to outlive this call.
    unawaited(_loop(token));
  }

  /// Nothing queued is lost — it's still on disk, ready for the next [start].
  void stop() => _activeToken = null;

  Future<void> _loop(Object token) async {
    var failureStreak = 0;
    while (identical(_activeToken, token)) {
      bool hitTransientFailure;
      try {
        hitTransientFailure = await _drainOnce();
      } catch (_) {
        // This loop must never let a surprise escape as an unhandled Future
        // rejection — treat it like a network failure and back off.
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
        // Clean drain: reset so the next real failure starts from the
        // shortest delay again instead of inheriting an old streak.
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

  /// Uploads whatever is pending right now, oldest batch first. Returns true
  /// if a transient failure cut the drain short, leaving remaining batches
  /// queued for the next attempt.
  Future<bool> _drainOnce() async {
    final List<Incident> incidents;
    try {
      incidents = queue.pending();
    } catch (_) {
      // Documented never to throw, but this loop must survive a surprise
      // anyway — treat it like a network failure and back off.
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

  /// Splits and retries on [PayloadTooLargeFailure] so one oversized
  /// incident costs only itself, not its batch-mates. Returns true if the
  /// caller should stop the whole drain for this round.
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
        // No amount of splitting helps one incident that's too large alone.
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
      // Network error, timeout, 5xx: stop here instead of moving to the next
      // batch, so a downed backend isn't hit once per remaining batch.
      return true;
    }
  }

  /// A single incident that fails to delete is left queued rather than
  /// lost — it's uploaded again next round, a harmless duplicate.
  void _removeQuietly(List<Incident> batch) {
    for (final incident in batch) {
      try {
        queue.remove(incident.id);
      } catch (_) {
        // Leave it queued for the next attempt.
      }
    }
  }

  void _discard(List<Incident> batch, String reason) {
    _removeQuietly(batch);
    debugPrint('incident_sdk: discarding ${batch.length} incident(s) — $reason');
  }

  /// Full jitter: the delay is chosen uniformly between zero and the capped
  /// value, so retries from many devices spread out instead of landing at
  /// once.
  Duration _backoff(int failureStreak) {
    // Cap the exponent, not just the result, to avoid overflow.
    final exponent = min(failureStreak - 1, 20);
    final grown = baseDelay.inMilliseconds * pow(2, exponent);
    final capped = min(grown.toDouble(), maxDelay.inMilliseconds.toDouble());
    return Duration(milliseconds: (_random.nextDouble() * capped).round());
  }
}

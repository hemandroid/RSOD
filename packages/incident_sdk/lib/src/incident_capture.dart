import 'dart:async';

import 'package:flutter/foundation.dart';

import 'build_identity.dart';
import 'incident.dart';
import 'incident_queue.dart';

/// Installs the error hooks and turns whatever they catch into a queued
/// [Incident].
///
/// Every path through here is synchronous and swallows its own errors. This
/// code runs while the app is failing; throwing from it would replace a
/// diagnosable crash with an undiagnosable one.
class IncidentCapture {
  final IncidentQueue queue;

  /// Extra context gathered at capture time (route, logs, network, device).
  /// Collectors are added in day 3; the hook shape does not change when they
  /// are.
  final Map<String, dynamic> Function()? collectContext;

  /// Called with the id of an incident that was just written to disk, for
  /// context that cannot be gathered synchronously (a screenshot needs a
  /// frame). Fire-and-forget and guarded: the incident is already safe, and
  /// nothing this does may affect it. See `IncidentQueue.amend`.
  final void Function(String incidentId)? onIncidentQueued;

  IncidentCapture({
    required this.queue,
    this.collectContext,
    this.onIncidentQueued,
  });

  var _sequence = 0;

  void install() {
    final previousOnError = FlutterError.onError;

    FlutterError.onError = (details) {
      _capture(
        source: IncidentSource.flutterError,
        error: details.exception.toString(),
        stack: details.stack?.toString() ?? '',
        errorContext: details.context?.toString(),
      );
      // Keep the default behaviour: in debug this still prints to the console,
      // and anyone who installed a handler before us still gets called.
      if (previousOnError != null) {
        previousOnError(details);
      } else {
        FlutterError.presentError(details);
      }
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      _capture(
        source: IncidentSource.platformDispatcher,
        error: error.toString(),
        stack: stack.toString(),
      );
      // Returning true marks the error handled, which stops the process from
      // being torn down. We report, then let the app keep running.
      return true;
    };
  }

  /// Wraps [body] so errors escaping async gaps are captured too. These never
  /// reach [FlutterError.onError].
  R? runGuarded<R>(R Function() body) {
    return runZonedGuarded<R>(body, (error, stack) {
      _capture(
        source: IncidentSource.zone,
        error: error.toString(),
        stack: stack.toString(),
      );
    });
  }

  /// Report a handled failure that still deserves a ticket — a failed payment
  /// call, a degraded response — without crashing the app.
  void report(Object error, StackTrace stack, {String? context}) => _capture(
        source: IncidentSource.manual,
        error: error.toString(),
        stack: stack.toString(),
        errorContext: context,
      );

  /// Report a recovered UI-thread stall. A tear-off of this is exactly
  /// `UiWatchdog`'s `StallCallback`.
  void reportStall(Duration stallDuration) {
    final ms = stallDuration.inMilliseconds;
    _capture(
      source: IncidentSource.uiStall,
      error: 'ANR: UI thread unresponsive for ${ms}ms (recovered)',
      // No stack: nothing threw. A synthesised one would point at the
      // watchdog, not the work that blocked the thread.
      stack: '',
      extraContext: {
        uiStallContextKey: {'duration_ms': ms},
      },
    );
  }

  void _capture({
    required IncidentSource source,
    required String error,
    required String stack,
    String? errorContext,
    Map<String, dynamic> extraContext = const {},
  }) {
    try {
      final incident = Incident(
        id: _nextId(),
        capturedAt: DateTime.now(),
        source: source,
        error: error,
        stackTrace: stack,
        errorContext: errorContext,
        appVersion: BuildIdentity.appVersion,
        commitSha: BuildIdentity.commitSha,
        platform: defaultTargetPlatform.name,
        // Collector output first: a collector must not be able to overwrite
        // the SDK's own signal about why it captured.
        context: {..._safeContext(), ...extraContext},
      );
      if (queue.enqueueSync(incident)) {
        try {
          onIncidentQueued?.call(incident.id);
        } catch (_) {
          // Must never cost an incident that is already on disk.
        }
      }
    } catch (_) {
      // Deliberately silent. See class doc.
    }
  }

  Map<String, dynamic> _safeContext() {
    if (collectContext == null) return const {};
    try {
      return collectContext!();
    } catch (_) {
      // A broken collector must not cost us the whole incident.
      return const {'_collector_error': true};
    }
  }

  /// Time-ordered and unique within a run. The queue sorts by filename, so the
  /// sequence suffix keeps ordering stable when two errors land in the same
  /// millisecond — which is exactly what a crash loop does.
  String _nextId() {
    final ms = DateTime.now().toUtc().millisecondsSinceEpoch;
    final seq = (_sequence++).toString().padLeft(4, '0');
    return '${ms.toString().padLeft(14, '0')}-$seq';
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'build_identity.dart';
import 'incident.dart';
import 'incident_queue.dart';

/// Installs the error hooks and turns whatever they catch into a queued
/// [Incident].
///
/// Every path through here is synchronous and swallows its own errors: this
/// runs while the app is failing, and throwing here would replace a
/// diagnosable crash with an undiagnosable one.
class IncidentCapture {
  final IncidentQueue queue;

  /// Extra context gathered at capture time (route, logs, network, device).
  final Map<String, dynamic> Function()? collectContext;

  /// Called with the id of an incident already written to disk, for context
  /// that can't be gathered synchronously (a screenshot needs a frame).
  /// Fire-and-forget and guarded — see `IncidentQueue.amend`.
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
      // Keep the default behaviour: anyone who installed a handler before us
      // still gets called.
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
      // being torn down.
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

  /// Report a handled failure that still deserves a ticket, without crashing
  /// the app.
  void report(Object error, StackTrace stack, {String? context}) => _capture(
        source: IncidentSource.manual,
        error: error.toString(),
        stack: stack.toString(),
        errorContext: context,
      );

  /// A tear-off of this is exactly `UiWatchdog`'s `StallCallback`.
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
        // Collector output first: a collector must not overwrite the SDK's
        // own signal about why it captured.
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

  /// Time-ordered and unique within a run — the sequence suffix keeps
  /// ordering stable when two errors land in the same millisecond, which is
  /// exactly what a crash loop does.
  String _nextId() {
    final ms = DateTime.now().toUtc().millisecondsSinceEpoch;
    final seq = (_sequence++).toString().padLeft(4, '0');
    return '${ms.toString().padLeft(14, '0')}-$seq';
  }
}

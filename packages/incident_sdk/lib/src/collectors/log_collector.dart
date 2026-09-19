import 'dart:collection';
import 'dart:convert';

import 'collector.dart';

/// Severity of a single [IncidentLog] entry. Deliberately small — this is a
/// breadcrumb trail for a crash report, not a logging framework.
enum LogLevel { debug, info, warning, error }

/// The SDK's own logging API.
///
/// Whatever is passed here is captured verbatim into every later incident, so
/// it must not carry user data: log the fact, not the value — `'checkout:
/// payment started'`, never the card number, email or token.
///
/// [debugPrint] is compiled out of release builds — exactly the environment
/// this SDK exists to observe — so an app that wants breadcrumbs in its
/// crash reports needs something else to call. This stays deliberately
/// minimal: no sinks, no formatters, no filtering. Just enough to answer
/// "what was the app doing right before this."
///
/// Register [collector] with `IncidentSDK.init` and call [log] from
/// wherever the app wants a breadcrumb recorded:
///
/// ```dart
/// final log = IncidentLog();
/// IncidentSDK.init(..., collectors: [log.collector]);
/// log.log('checkout: applied coupon SAVE10');
/// ```
class IncidentLog {
  IncidentLog({this.maxEntries = 100, this.maxBytes = 16 * 1024});

  /// Hard cap on entry count, independent of [maxBytes] — a flood of short
  /// messages is bounded even though it would never hit the byte cap.
  final int maxEntries;

  /// Hard cap on total message bytes, independent of [maxEntries] — a
  /// handful of large messages is bounded even though it would never hit
  /// the entry-count cap.
  final int maxBytes;

  final _entries = Queue<_LogEntry>();
  int _bytes = 0;

  /// Records a breadcrumb. Never throws — a logging call must never become
  /// a new crash in the app it is instrumenting.
  void log(String message, {LogLevel level = LogLevel.info}) {
    try {
      final entry = _LogEntry(level, message, DateTime.now());
      _entries.add(entry);
      _bytes += entry.approxBytes;
      // ponytail: a single message larger than maxBytes empties the buffer
      // rather than being truncated in place. Callers control message
      // size today; revisit with per-entry truncation if that stops being
      // true (e.g. logging raw request/response bodies).
      while (_bytes > maxBytes || _entries.length > maxEntries) {
        _bytes -= _entries.removeFirst().approxBytes;
      }
    } catch (_) {
      // See class doc: logging must never be the thing that crashes.
    }
  }

  /// This buffer's output, registered under the name `logs`.
  IncidentCollector get collector => (
        name: 'logs',
        collect: () => {
          'entries': _entries.map((e) => e.toJson()).toList(growable: false),
        },
      );
}

class _LogEntry {
  _LogEntry(this.level, this.message, this.at);

  final LogLevel level;
  final String message;
  final DateTime at;

  /// UTF-8 byte length, not [String.length] — the byte cap exists to bound
  /// memory, and a string full of multi-byte characters would blow past it
  /// while looking compliant under `.length`.
  int get approxBytes => utf8.encode(message).length;

  Map<String, dynamic> toJson() => {
        'level': level.name,
        'message': message,
        'at': at.toIso8601String(),
      };
}

import 'dart:collection';
import 'dart:convert';

import 'collector.dart';

/// Severity of a single [IncidentLog] entry. Deliberately small — this is a
/// breadcrumb trail for a crash report, not a logging framework.
enum LogLevel { debug, info, warning, error }

/// The SDK's own logging API.
///
/// Captured verbatim into every incident — log the fact, not the value
/// (never a card number, email, or token).
///
/// [debugPrint] is compiled out of release builds, so this exists as
/// something breadcrumbs can still go through there. Register [collector]
/// with `IncidentSDK.init` and call [log] to record one.
class IncidentLog {
  IncidentLog({this.maxEntries = 100, this.maxBytes = 16 * 1024});

  final int maxEntries;

  final int maxBytes;

  final _entries = Queue<_LogEntry>();
  int _bytes = 0;

  /// Records a breadcrumb. Never throws — a logging call must never crash
  /// the app it's instrumenting.
  void log(String message, {LogLevel level = LogLevel.info}) {
    try {
      final entry = _LogEntry(level, message, DateTime.now());
      _entries.add(entry);
      _bytes += entry.approxBytes;
      // ponytail: a message larger than maxBytes empties the buffer rather
      // than truncating it; revisit if callers ever log large bodies.
      while (_bytes > maxBytes || _entries.length > maxEntries) {
        _bytes -= _entries.removeFirst().approxBytes;
      }
    } catch (_) {
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

  /// UTF-8 byte length, not [String.length] — multi-byte characters would
  /// blow past the byte cap while looking compliant under `.length`.
  int get approxBytes => utf8.encode(message).length;

  Map<String, dynamic> toJson() => {
        'level': level.name,
        'message': message,
        'at': at.toIso8601String(),
      };
}

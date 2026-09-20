import 'dart:convert';

/// How the failure reached us. Determines which hook caught it.
enum IncidentSource { flutterError, platformDispatcher, zone, manual, uiStall }

/// Key under which a [IncidentSource.uiStall] incident carries its measured
/// stall in [Incident.context], as `{'duration_ms': <int>}`.
const String uiStallContextKey = 'ui_stall';

/// A captured production failure, with whatever context we could gather.
///
/// Serialisation must stay cheap: this is built and written to disk on the
/// crash path, where we may have milliseconds.
class Incident {
  final String id;
  final DateTime capturedAt;
  final IncidentSource source;
  final String error;

  /// Raw, unsymbolicated in release builds. The backend decodes it using the
  /// symbols file matching [commitSha].
  final String stackTrace;

  /// Where Flutter says this happened ("building _FooWidget(dirty)").
  final String? errorContext;

  /// Without [commitSha] the backend can't pick the right symbols file, and
  /// the trace stays unreadable.
  final String appVersion;
  final String commitSha;
  final String platform;

  /// Collector output, keyed by collector name. Kept loose on purpose so
  /// adding a collector never changes this class or the wire format.
  final Map<String, dynamic> context;

  Incident({
    required this.id,
    required this.capturedAt,
    required this.source,
    required this.error,
    required this.stackTrace,
    required this.appVersion,
    required this.commitSha,
    required this.platform,
    this.errorContext,
    this.context = const {},
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'captured_at': capturedAt.toUtc().toIso8601String(),
        'source': source.name,
        'error': error,
        'stack_trace': stackTrace,
        if (errorContext != null) 'error_context': errorContext,
        'app_version': appVersion,
        'commit_sha': commitSha,
        'platform': platform,
        'context': context,
      };

  static Incident fromJson(Map<String, dynamic> json) => Incident(
        id: json['id'] as String,
        capturedAt: DateTime.parse(json['captured_at'] as String),
        source: IncidentSource.values.firstWhere(
          (s) => s.name == json['source'],
          // Unknown source (queued by a newer build, read after a downgrade)
          // must not lose the incident; `manual` claims the least.
          orElse: () => IncidentSource.manual,
        ),
        error: json['error'] as String,
        stackTrace: json['stack_trace'] as String,
        errorContext: json['error_context'] as String?,
        appVersion: json['app_version'] as String,
        commitSha: json['commit_sha'] as String,
        platform: json['platform'] as String,
        context: (json['context'] as Map?)?.cast<String, dynamic>() ?? const {},
      );

  String encode() => jsonEncode(toJson());
}

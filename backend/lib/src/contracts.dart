library;

/// Where a component reports its own failures. Never receives a secret.
typedef Log = void Function(String message);

/// Mirrors `IncidentSource` in the Flutter package; an unknown value degrades
/// to [manual] rather than dropping the incident.
enum IncidentSource { flutterError, platformDispatcher, zone, manual, uiStall }

/// Key for a [IncidentSource.uiStall]'s measured stall in [Incident.context],
/// as `{'duration_ms': <int>}`.
const String uiStallContextKey = 'ui_stall';

/// Mirrors the SDK's `Incident.toJson` byte for byte; a rename on either side
/// silently drops data.
class Incident {
  const Incident({
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

  final String id;
  final DateTime capturedAt;
  final IncidentSource source;
  final String error;

  /// Unsymbolicated in release builds; see [Symbolicator].
  final String stackTrace;

  final String? errorContext;
  final String appVersion;
  final String commitSha;
  final String platform;

  /// Collector output keyed by collector name: `device`, `logs`, `routes`,
  /// `network`, `screenshot`, `ui_stall`. Deliberately untyped so a new
  /// collector never requires a change here.
  final Map<String, dynamic> context;

  static Incident fromJson(Map<String, dynamic> json) => Incident(
        id: json['id'] as String,
        capturedAt: DateTime.parse(json['captured_at'] as String),
        source: IncidentSource.values.firstWhere(
          (s) => s.name == json['source'],
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
}

/// What the model made of an incident. Malformed model output degrades a
/// field to null rather than failing the pipeline — a ticket without a root
/// cause still beats no ticket.
class Analysis {
  const Analysis({
    required this.title,
    required this.rootCause,
    required this.reproSteps,
    this.severity,
    this.suggestedFix,
  });

  /// Never contains the raw stack trace.
  final String title;
  final String rootCause;
  final List<String> reproSteps;

  /// `blocker` | `major` | `minor`, or null if the model did not say.
  final String? severity;
  final String? suggestedFix;
}

class Ticket {
  const Ticket({required this.key, required this.url});

  final String key;

  /// Human-clickable, built from the site URL rather than the API gateway.
  final String url;
}

/// Turns an incident into an [Analysis]. Implementations must not depend on
/// provider-specific features (JSON mode, tool calling) — swapping to Azure
/// AI Foundry must be a config change, not a code change.
abstract interface class IncidentAnalyzer {
  /// Returns null on any failure; never throws.
  Future<Analysis?> analyse(Incident incident, String symbolicatedTrace);
}

abstract interface class TicketFiler {
  Future<Ticket?> file(
    Incident incident,
    Analysis? analysis,
    String symbolicatedTrace,
  );

  /// Returns the ticket (only the filer knows the clickable site URL), or
  /// null if the comment could not be added.
  Future<Ticket?> comment(String issueKey, Incident incident);
}

/// Posts to a group channel and to one person.
abstract interface class Notifier {
  /// [ticket] null means filing failed; the message must say so loudly since
  /// Slack is then the only signal anyone gets.
  Future<void> announce({
    required Incident incident,
    required Analysis? analysis,
    required Ticket? ticket,
    required bool isRepeat,
    String? failureNote,
  });
}

abstract interface class Symbolicator {
  /// Returns the input unchanged if no symbols match; never throws.
  Future<String> symbolicate(String stackTrace, String commitSha);
}

/// Remembers which fingerprint produced which ticket, so the same failure
/// tapped repeatedly in rehearsal is one ticket with several comments.
abstract interface class DedupeStore {
  Future<String?> lookup(String fingerprint);

  Future<void> remember(String fingerprint, String issueKey);
}

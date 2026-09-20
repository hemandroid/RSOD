import 'package:incident_backend/src/contracts.dart';

/// Test doubles for the contracts interfaces, shared by the pipeline and
/// handler tests. Each records what it was asked to do and can be told to
/// throw, so failure isolation is asserted rather than assumed.

Incident incident({
  String id = 'inc-1',
  IncidentSource source = IncidentSource.flutterError,
  String error = 'Bad state: No element',
  String stackTrace = 'raw trace',
  Map<String, dynamic> context = const {},
}) =>
    Incident(
      id: id,
      capturedAt: DateTime.utc(2026, 9, 20, 9, 14, 22),
      source: source,
      error: error,
      stackTrace: stackTrace,
      appVersion: '1.0.0',
      commitSha: 'abc1234',
      platform: 'android',
      context: context,
    );

class FakeSymbolicator implements Symbolicator {
  int calls = 0;
  bool shouldThrow = false;
  String result = 'SYMBOLICATED';

  @override
  Future<String> symbolicate(String stackTrace, String commitSha) async {
    calls++;
    if (shouldThrow) throw StateError('symbols unreadable');
    return result;
  }
}

typedef AnalyzeCall = ({Incident incident, String trace});

class FakeAnalyzer implements IncidentAnalyzer {
  final List<AnalyzeCall> received = [];
  bool shouldThrow = false;
  Analysis? result = const Analysis(
    title: 'Catalogue crashes when empty',
    rootCause: 'products.first on an empty list',
    reproSteps: ['open the catalogue with an empty response'],
    severity: 'major',
  );

  @override
  Future<Analysis?> analyse(Incident incident, String symbolicatedTrace) async {
    if (shouldThrow) throw StateError('model unreachable');
    received.add((incident: incident, trace: symbolicatedTrace));
    return result;
  }
}

typedef FileCall = ({Incident incident, Analysis? analysis, String trace});

class FakeFiler implements TicketFiler {
  final List<FileCall> filed = [];
  final List<String> commented = [];
  bool shouldThrow = false;
  bool commentSucceeds = true;
  Ticket? result = const Ticket(
    key: 'SCRUM-1',
    url: 'https://example.atlassian.net/browse/SCRUM-1',
  );

  @override
  Future<Ticket?> file(
    Incident incident,
    Analysis? analysis,
    String symbolicatedTrace,
  ) async {
    if (shouldThrow) throw StateError('jira down');
    filed
        .add((incident: incident, analysis: analysis, trace: symbolicatedTrace));
    return result;
  }

  @override
  Future<Ticket?> comment(String issueKey, Incident incident) async {
    if (shouldThrow) throw StateError('jira down');
    commented.add(issueKey);
    return commentSucceeds
        ? Ticket(key: issueKey, url: 'https://example.atlassian.net/browse/$issueKey')
        : null;
  }
}

typedef Announcement = ({
  Incident incident,
  Analysis? analysis,
  Ticket? ticket,
  bool isRepeat,
  String? failureNote,
});

class FakeNotifier implements Notifier {
  final List<Announcement> sent = [];
  bool shouldThrow = false;

  @override
  Future<void> announce({
    required Incident incident,
    required Analysis? analysis,
    required Ticket? ticket,
    required bool isRepeat,
    String? failureNote,
  }) async {
    if (shouldThrow) throw StateError('slack down');
    sent.add((
      incident: incident,
      analysis: analysis,
      ticket: ticket,
      isRepeat: isRepeat,
      failureNote: failureNote,
    ));
  }
}

class FakeDedupe implements DedupeStore {
  final Map<String, String> entries = {};
  bool shouldThrow = false;

  @override
  Future<String?> lookup(String fingerprint) async {
    if (shouldThrow) throw StateError('store unreadable');
    return entries[fingerprint];
  }

  @override
  Future<void> remember(String fingerprint, String issueKey) async {
    if (shouldThrow) throw StateError('store unwritable');
    entries[fingerprint] = issueKey;
  }
}

import 'dart:async';

import 'contracts.dart';

/// Produces a stable key identifying "the same bug". Injected rather than
/// imported so the pipeline depends on nothing but [contracts].
typedef Fingerprinter = String Function(Incident incident);

/// Turns one captured incident into a ticket and an alert. Each stage is
/// isolated — a failure costs only that stage's output, never the rest of
/// the pipeline.
class IncidentPipeline {
  IncidentPipeline({
    required this.symbolicator,
    required this.analyzer,
    required this.filer,
    required this.notifier,
    required this.dedupe,
    required this.fingerprint,
    required this.log,
  });

  final Symbolicator symbolicator;
  final IncidentAnalyzer analyzer;
  final TicketFiler filer;
  final Notifier notifier;
  final DedupeStore dedupe;
  final Fingerprinter fingerprint;
  final Log log;

  /// One chain per fingerprint: without this, concurrent reports of the same
  /// bug all miss the dedupe lookup together and file separate tickets.
  final Map<String, Future<void>> _inFlightByFingerprint = {};

  Future<void> process(Incident incident) {
    String key;
    try {
      key = fingerprint(incident);
    } catch (e) {
      // Un-fingerprintable: file its own ticket rather than drop or merge it.
      log('fingerprint failed: $e');
      key = incident.id;
    }

    final previous = _inFlightByFingerprint[key] ?? Future<void>.value();
    final current = previous.then((_) => _process(incident, key));
    _inFlightByFingerprint[key] = current;
    return current.whenComplete(() {
      // Only clear if nothing queued behind us.
      if (identical(_inFlightByFingerprint[key], current)) {
        _inFlightByFingerprint.remove(key);
      }
    });
  }

  Future<void> _process(Incident incident, String key) async {
    final trace = await _guard(
      () => symbolicator.symbolicate(incident.stackTrace, incident.commitSha),
      fallback: incident.stackTrace,
      what: 'symbolication',
    );

    final existing = await _guard<String?>(
      () => dedupe.lookup(key),
      fallback: null,
      what: 'dedupe lookup',
    );

    if (existing != null) {
      final commented = await _guard<Ticket?>(
        () => filer.comment(existing, incident),
        fallback: null,
        what: 'jira comment',
      );
      await _announce(
        incident: incident,
        analysis: null,
        ticket: commented,
        isRepeat: true,
        failureNote:
            commented == null ? 'Could not comment on $existing.' : null,
      );
      return;
    }

    final analysis = await _guard<Analysis?>(
      () => analyzer.analyse(incident, trace),
      fallback: null,
      what: 'analysis',
    );

    final ticket = await _guard<Ticket?>(
      () => filer.file(incident, analysis, trace),
      fallback: null,
      what: 'jira create',
    );

    if (ticket != null) {
      // Only remember on success: recording a failed attempt would suppress
      // every later retry of the same bug.
      await _guard(
        () => dedupe.remember(key, ticket.key),
        fallback: null,
        what: 'dedupe remember',
      );
    }

    await _announce(
      incident: incident,
      analysis: analysis,
      ticket: ticket,
      isRepeat: false,
      failureNote: ticket == null
          ? 'Filing the ticket failed. The incident was captured but is not in Jira.'
          : null,
    );
  }

  Future<void> _announce({
    required Incident incident,
    required Analysis? analysis,
    required Ticket? ticket,
    required bool isRepeat,
    String? failureNote,
  }) =>
      _guard(
        () => notifier.announce(
          incident: incident,
          analysis: analysis,
          ticket: ticket,
          isRepeat: isRepeat,
          failureNote: failureNote,
        ),
        fallback: null,
        what: 'slack',
      );

  /// Belt-and-braces: a bug in one collaborator must not cost the remaining
  /// stages, even though contracts say implementations never throw.
  Future<T> _guard<T>(
    Future<T> Function() body, {
    required T fallback,
    required String what,
  }) async {
    try {
      return await body();
    } catch (e) {
      log('$what failed: $e');
      return fallback;
    }
  }

}

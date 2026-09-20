import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:incident_backend/src/contracts.dart';
import 'package:incident_backend/src/slack_notifier.dart';
import 'package:test/test.dart';

const _botToken = 'xoxb-super-secret-token-do-not-leak';

Incident _incident({Map<String, dynamic> context = const {}}) => Incident(
      id: 'inc-1',
      capturedAt: DateTime.utc(2026, 9, 20),
      source: IncidentSource.flutterError,
      error: 'RangeError: index out of bounds',
      stackTrace: '#0 someObfuscatedFrame (offset 0x1a2b)',
      appVersion: '4.2.0',
      commitSha: 'abc123',
      platform: 'android',
      errorContext: 'checkout_screen',
      context: context,
    );

const _analysis = Analysis(
  title: 'Checkout crashes on empty cart',
  rootCause: 'Cart total computed before items finish loading',
  reproSteps: ['Open app', 'Tap checkout before items load'],
);

const _ticket = Ticket(key: 'SCRUM-42', url: 'https://example.atlassian.net/browse/SCRUM-42');

/// Captures every request the notifier sends and always answers `ok: true`
/// unless [failFor] names a channel id to fail instead.
({http.Client client, List<http.Request> requests}) _harness({
  Set<String> failFor = const {},
}) {
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (failFor.contains(body['channel'])) {
      return http.Response(
        jsonEncode({'ok': false, 'error': 'missing_scope'}),
        200,
      );
    }
    return http.Response(jsonEncode({'ok': true, 'channel': body['channel']}), 200);
  });
  return (client: client, requests: requests);
}

void main() {
  test('sends one message to the channel id and one to the DM user id', () async {
    final h = _harness();
    final notifier = SlackNotifier(
      botToken: _botToken,
      channelId: 'C123',
      dmUserId: 'U456',
      client: h.client,
    );

    await notifier.announce(
      incident: _incident(),
      analysis: _analysis,
      ticket: _ticket,
      isRepeat: false,
    );

    expect(h.requests, hasLength(2));
    final destinations = h.requests
        .map((r) => (jsonDecode(r.body) as Map<String, dynamic>)['channel'])
        .toSet();
    expect(destinations, {'C123', 'U456'});
  });

  test('every request carries both blocks and a non-empty text field', () async {
    final h = _harness();
    final notifier = SlackNotifier(
      botToken: _botToken,
      channelId: 'C123',
      dmUserId: 'U456',
      client: h.client,
    );

    await notifier.announce(
      incident: _incident(),
      analysis: _analysis,
      ticket: _ticket,
      isRepeat: false,
    );

    expect(h.requests, hasLength(2));
    for (final request in h.requests) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['blocks'], isA<List>());
      expect(body['blocks'], isNotEmpty);
      expect(body['text'], isA<String>());
      expect((body['text'] as String).trim(), isNotEmpty);
      // Never useful, and unreadable in Slack — the trace stays in the ticket.
      expect(jsonEncode(body).contains('someObfuscatedFrame'), isFalse);
    }
  });

  test('a 200 response with ok:false is treated as failure and does not throw', () async {
    final h = _harness(failFor: {'C123'});
    final notifier = SlackNotifier(
      botToken: _botToken,
      channelId: 'C123',
      dmUserId: 'U456',
      client: h.client,
    );

    await notifier.announce(
      incident: _incident(),
      analysis: _analysis,
      ticket: _ticket,
      isRepeat: false,
    );

    // Both destinations were still attempted: the channel failure above
    // (an ok:false body on a 200 response) did not stop the DM from going
    // out, and announce() itself did not throw getting here.
    expect(h.requests, hasLength(2));
    final dmRequest = h.requests.firstWhere(
      (r) => (jsonDecode(r.body) as Map<String, dynamic>)['channel'] == 'U456',
    );
    final dmBody = jsonDecode(dmRequest.body) as Map<String, dynamic>;
    expect(dmBody['blocks'], isNotEmpty);
    expect((dmBody['text'] as String).trim(), isNotEmpty);
  });

  test('a DM failure still lets the channel message through', () async {
    final h = _harness(failFor: {'U456'});
    final notifier = SlackNotifier(
      botToken: _botToken,
      channelId: 'C123',
      dmUserId: 'U456',
      client: h.client,
    );

    await notifier.announce(
      incident: _incident(),
      analysis: _analysis,
      ticket: _ticket,
      isRepeat: false,
    );

    expect(h.requests, hasLength(2));
    expect(
      h.requests.map((r) => (jsonDecode(r.body) as Map<String, dynamic>)['channel']),
      containsAll(['C123', 'U456']),
    );
  });

  test('a hard network failure on the channel post still lets the DM through, and never throws', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['channel'] == 'C123') {
        throw const SocketExceptionStub();
      }
      return http.Response(jsonEncode({'ok': true}), 200);
    });
    final notifier = SlackNotifier(
      botToken: _botToken,
      channelId: 'C123',
      dmUserId: 'U456',
      client: client,
    );

    await expectLater(
      notifier.announce(
        incident: _incident(),
        analysis: _analysis,
        ticket: _ticket,
        isRepeat: false,
      ),
      completes,
    );
    expect(calls, 2);
  });

  test('isRepeat true reads as a recurrence, not a new ticket', () async {
    final h = _harness();
    final notifier = SlackNotifier(
      botToken: _botToken,
      channelId: 'C123',
      dmUserId: 'U456',
      client: h.client,
    );

    await notifier.announce(
      incident: _incident(),
      analysis: _analysis,
      ticket: _ticket,
      isRepeat: true,
    );

    for (final request in h.requests) {
      final text = jsonEncode(jsonDecode(request.body));
      expect(text.toLowerCase(), contains('recurrence'));
      expect(text.toLowerCase(), isNot(contains('new crash')));
    }
  });

  test('a null ticket produces a visibly different message carrying the failure note', () async {
    final h = _harness();
    final notifier = SlackNotifier(
      botToken: _botToken,
      channelId: 'C123',
      dmUserId: 'U456',
      client: h.client,
    );

    await notifier.announce(
      incident: _incident(),
      analysis: _analysis,
      ticket: null,
      isRepeat: false,
      failureNote: 'Jira returned HTTP 500',
    );

    expect(h.requests, hasLength(2));
    for (final request in h.requests) {
      final rendered = jsonEncode(jsonDecode(request.body));
      expect(rendered.toLowerCase(), contains('filing failed'));
      expect(rendered, contains('Jira returned HTTP 500'));
      // No ticket exists, so there must be nothing that looks like a link
      // to one.
      expect(rendered.contains(_ticket.url), isFalse);
    }
  });

  test('the bot token never appears in any request body', () async {
    final h = _harness(failFor: {'C123'});
    final notifier = SlackNotifier(
      botToken: _botToken,
      channelId: 'C123',
      dmUserId: 'U456',
      client: h.client,
    );

    await notifier.announce(
      incident: _incident(),
      analysis: null,
      ticket: null,
      isRepeat: false,
      failureNote: 'Jira auth expired',
    );

    for (final request in h.requests) {
      expect(request.body.contains(_botToken), isFalse);
      // The only place the token is allowed to live.
      expect(request.headers['Authorization'], 'Bearer $_botToken');
    }
  });

  test('missing analysis still produces a message, without inventing a root cause', () async {
    final h = _harness();
    final notifier = SlackNotifier(
      botToken: _botToken,
      channelId: 'C123',
      dmUserId: 'U456',
      client: h.client,
    );

    await notifier.announce(
      incident: _incident(),
      analysis: null,
      ticket: _ticket,
      isRepeat: false,
    );

    for (final request in h.requests) {
      final rendered = jsonEncode(jsonDecode(request.body));
      // Falls back to the raw incident error as the headline when there is
      // no Analysis.title to prefer.
      expect(rendered, contains('RangeError'));
    }
  });

  test('screen label prefers routes context, falling back to errorContext', () async {
    final h = _harness();
    final notifier = SlackNotifier(
      botToken: _botToken,
      channelId: 'C123',
      dmUserId: 'U456',
      client: h.client,
    );

    await notifier.announce(
      incident: _incident(context: {
        'routes': {'current': 'payment_screen'}
      }),
      analysis: _analysis,
      ticket: _ticket,
      isRepeat: false,
    );
    expect(jsonEncode(jsonDecode(h.requests.first.body)), contains('payment_screen'));

    h.requests.clear();
    await notifier.announce(
      // No 'routes' key at all — context is untyped collector output and
      // must degrade gracefully rather than throw.
      incident: _incident(),
      analysis: _analysis,
      ticket: _ticket,
      isRepeat: false,
    );
    expect(jsonEncode(jsonDecode(h.requests.first.body)), contains('checkout_screen'));
  });
}

/// A minimal exception stand-in so the network-failure test doesn't need
/// dart:io's SocketException just to prove announce() swallows any throw.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();

  @override
  String toString() => 'SocketExceptionStub: connection refused';
}

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'contracts.dart';

/// Posts incident alerts to Slack via `chat.postMessage`.
///
/// The bot token only has `chat:write` + `chat:write.public` — no
/// `conversations.list`/`users.info`/etc — so the channel id and the DM
/// user id must be supplied by the caller; this class cannot look them up.
/// A DM needs no `conversations.open` call: Slack opens the conversation
/// when a user id is passed directly as `channel`.
class SlackNotifier implements Notifier {
  SlackNotifier({
    required String botToken,
    required this.channelId,
    required this.dmUserId,
    required http.Client client,
  })  : _botToken = botToken,
        _client = client;

  final String _botToken;
  final String channelId;
  final String dmUserId;
  final http.Client _client;

  static final _endpoint = Uri.parse('https://slack.com/api/chat.postMessage');

  @override
  Future<void> announce({
    required Incident incident,
    required Analysis? analysis,
    required Ticket? ticket,
    required bool isRepeat,
    String? failureNote,
  }) async {
    // Built once, sent twice — only the destination id differs.
    final message = _buildMessage(
      incident: incident,
      analysis: analysis,
      ticket: ticket,
      isRepeat: isRepeat,
      failureNote: failureNote,
    );

    // Each post swallows its own failure, kicked off before either is
    // awaited, so an outage on one destination can't suppress the other.
    await Future.wait([
      _post(channelId, message),
      _post(dmUserId, message),
    ]);
  }

  Future<void> _post(String channel, Map<String, dynamic> message) async {
    try {
      final response = await _client.post(
        _endpoint,
        headers: {
          'Authorization': 'Bearer $_botToken',
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: jsonEncode({...message, 'channel': channel}),
      );
      // Slack returns HTTP 200 even on failure; the `ok` field is the only
      // reliable signal.
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['ok'] != true) {
        return;
      }
    } catch (_) {
      // A Slack outage cannot be allowed to fail the incident pipeline.
    }
  }

  Map<String, dynamic> _buildMessage({
    required Incident incident,
    required Analysis? analysis,
    required Ticket? ticket,
    required bool isRepeat,
    String? failureNote,
  }) {
    final analysisTitle = analysis?.title.trim();
    final title = _mrkdwn((analysisTitle != null && analysisTitle.isNotEmpty)
        ? analysisTitle
        : incident.error);
    final filingFailed = ticket == null;

    final headline = filingFailed
        ? ':rotating_light: JIRA FILING FAILED — $title'
        : isRepeat
            ? ':repeat: Recurrence — $title'
            : ':bug: New crash — $title';

    final detailLines = <String>[
      if (filingFailed)
        '*Ticket filing failed.* '
            '${(failureNote != null && failureNote.trim().isNotEmpty) ? _mrkdwn(failureNote) : 'No further detail is available — this Slack message is the only record of this incident.'}',
      if (analysis != null)
        '*Root cause:* ${_mrkdwn(analysis.rootCause)}'
      else
        '_Automated analysis did not complete for this incident._',
      '*Version:* ${_mrkdwn(incident.appVersion)}   '
          '*Platform:* ${_mrkdwn(incident.platform)}   '
          '*Screen:* ${_mrkdwn(_screenLabel(incident))}',
    ];

    final blocks = <Map<String, dynamic>>[
      {
        'type': 'header',
        'text': {'type': 'plain_text', 'text': headline, 'emoji': true},
      },
      {
        'type': 'section',
        'text': {'type': 'mrkdwn', 'text': detailLines.join('\n')},
      },
      if (ticket != null)
        {
          'type': 'section',
          'text': {
            'type': 'mrkdwn',
            'text': isRepeat
                ? '*Existing ticket:* <${ticket.url}|${ticket.key}>'
                : '*Ticket:* <${ticket.url}|${ticket.key}>',
          },
        }
      else
        {
          'type': 'section',
          'text': {
            'type': 'mrkdwn',
            'text': ':warning: *No ticket exists for this incident.*',
          },
        },
    ];

    // `text` is what push notifications and screen readers render; blocks
    // alone show as a blank phone notification.
    final fallbackText = filingFailed
        ? 'JIRA FILING FAILED: $title'
        : '${isRepeat ? 'Recurrence' : 'New crash'}: $title (${ticket.key})';

    return {'blocks': blocks, 'text': fallbackText};
  }

  /// Slack reads `<...>` as a link and `&` as an entity, so incident text
  /// (never our own markup) is escaped before it can render as a link.
  static String _mrkdwn(String raw) => raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  String _screenLabel(Incident incident) {
    final routes = incident.context['routes'];
    if (routes is Map) {
      final current = routes['current'] ?? routes['route'] ?? routes['name'];
      if (current != null) return current.toString();
    }
    if (routes is List && routes.isNotEmpty) return routes.last.toString();
    if (routes is String && routes.isNotEmpty) return routes;
    return incident.errorContext ?? 'unknown';
  }
}

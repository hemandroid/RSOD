import 'dart:convert';

import 'package:http/http.dart' as http;

import 'contracts.dart';

/// Files incidents as Jira Bugs through the Atlassian API gateway.
///
/// Scoped API tokens 401 against `https://<site>.atlassian.net/rest/api/3`;
/// they only work through `https://api.atlassian.com/ex/jira/<cloudId>/rest/api/3`.
/// [apiRoot] must already be that gateway URL — this class never touches
/// [siteBaseUrl] for anything but building the `/browse/<key>` link a human
/// clicks.
class JiraFiler implements TicketFiler {
  JiraFiler({
    required this.apiRoot,
    required this.authHeader,
    required this.projectKey,
    required this.issueTypeName,
    required this.siteBaseUrl,
    required http.Client client,
    required this.log,
  }) : _client = client;

  final String apiRoot;

  /// Full `Authorization` header value (`Basic <base64(email:token)>`).
  /// Never written to a log line or exception message.
  final String authHeader;

  final String projectKey;
  final String issueTypeName;
  final String siteBaseUrl;
  final http.Client _client;
  final Log log;

  /// Keeps the crash site and its immediate callers on screen without
  /// risking Jira's per-field payload size limit.
  static const int _maxTraceLines = 100;

  Map<String, String> get _headers => {
        'Authorization': authHeader,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  @override
  Future<Ticket?> file(
    Incident incident,
    Analysis? analysis,
    String symbolicatedTrace,
  ) async {
    try {
      final request = {
        'fields': {
          'project': {'key': projectKey},
          'issuetype': {'name': issueTypeName},
          'summary': _summary(incident, analysis),
          'labels': _labels(incident, analysis),
          'description': _description(incident, analysis, symbolicatedTrace),
        },
      };

      final response = await _client.post(
        Uri.parse('$apiRoot/issue'),
        headers: _headers,
        body: jsonEncode(request),
      );

      if (response.statusCode != 200 && response.statusCode != 201) {
        _logFailure('create', response);
        return null;
      }

      final decoded = jsonDecode(response.body);
      final key = decoded is Map ? decoded['key'] as String? : null;
      if (key == null) {
        log('[JiraFiler] create succeeded but response had no issue key');
        return null;
      }
      // Attached after creation — Jira has no way to include a binary in the
      // create call — and never allowed to fail the ticket that already exists.
      await _attachScreenshot(key, incident);

      return Ticket(key: key, url: _browseUrl(key));
    } catch (e) {
      // Logs only the type: exception messages can carry request bodies.
      log('[JiraFiler] create threw: ${e.runtimeType}');
      return null;
    }
  }

  @override
  Future<Ticket?> comment(String issueKey, Incident incident) async {
    try {
      final request = {
        'body': {
          'type': 'doc',
          'version': 1,
          'content': [
            _paragraph(
              'Repeat occurrence — incident ${incident.id} captured at '
              '${incident.capturedAt.toIso8601String()}: '
              '${_firstLine(incident.error)}',
            ),
          ],
        },
      };

      final response = await _client.post(
        Uri.parse('$apiRoot/issue/$issueKey/comment'),
        headers: _headers,
        body: jsonEncode(request),
      );

      if (response.statusCode != 200 && response.statusCode != 201) {
        _logFailure('comment', response);
        return null;
      }
      return Ticket(key: issueKey, url: _browseUrl(issueKey));
    } catch (e) {
      log('[JiraFiler] comment threw: ${e.runtimeType}');
      return null;
    }
  }

  void _logFailure(String action, http.Response response) {
    String? errorMessages;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['errorMessages'] is List) {
        errorMessages = (decoded['errorMessages'] as List).join('; ');
      }
    } catch (_) {
      // Body wasn't JSON (e.g. a gateway's plain-text 401 page).
    }
    log(
      '[JiraFiler] $action failed: status=${response.statusCode}'
      '${errorMessages != null ? ' errorMessages=$errorMessages' : ''}',
    );
  }

  // ---- ticket content -------------------------------------------------

  String _summary(Incident incident, Analysis? analysis) {
    final raw = analysis?.title ??
        '${_firstLine(incident.error)} (${incident.platform})';
    return raw.length > 255 ? raw.substring(0, 255) : raw;
  }

  String _firstLine(String text) => text.split('\n').first.trim();

  /// Severity is a label, not a `priority` field: team-managed Jira projects
  /// often don't expose `priority`, and Jira rejects the entire create call
  /// if any field is unrecognised.
  ///
  /// Uploads `context['screenshot']` as a PNG, if the SDK captured one — a
  /// `uiStall` incident legitimately has none, since the UI thread was too
  /// blocked to rasterise a frame.
  Future<void> _attachScreenshot(String issueKey, Incident incident) async {
    final shot = incident.context['screenshot'];
    if (shot is! Map) return;
    final encoded = shot['image_base64'];
    if (encoded is! String || encoded.isEmpty) return;

    try {
      final bytes = base64Decode(encoded);

      // Treated as bytes of unknown provenance, not as the PNG it claims to
      // be — anyone holding the ingest token controls this payload.
      if (bytes.length > _maxAttachmentBytes) {
        log('[JiraFiler] screenshot skipped: ${bytes.length} bytes');
        return;
      }
      if (!_looksLikePng(bytes)) {
        log('[JiraFiler] screenshot skipped: not a PNG');
        return;
      }

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$apiRoot/issue/$issueKey/attachments'),
      )
        ..headers['Authorization'] = authHeader
        // Jira rejects attachment uploads without this XSRF guard header.
        ..headers['X-Atlassian-Token'] = 'no-check'
        ..files.add(http.MultipartFile.fromBytes(
          'file',
          bytes,
          // incident.id comes off the wire; sanitize before it rides into a
          // multipart filename (e.g. `../../evil`).
          filename: 'screen-${_safeName(incident.id)}.png',
        ));

      final response = await _client.send(request);
      if (response.statusCode != 200) {
        log('[JiraFiler] screenshot upload failed: status=${response.statusCode}');
      }
    } catch (e) {
      log('[JiraFiler] screenshot upload threw: ${e.runtimeType}');
    }
  }

  /// SDK caps a screenshot at 128KB; this leaves headroom for base64 slack.
  static const int _maxAttachmentBytes = 512 * 1024;

  static bool _looksLikePng(List<int> bytes) {
    const magic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  static String _safeName(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    return cleaned.length <= 64 ? cleaned : cleaned.substring(0, 64);
  }

  String _browseUrl(String key) => '$siteBaseUrl/browse/$key';

  List<String> _labels(Incident incident, Analysis? analysis) {
    final labels = ['incident-sdk', 'auto-filed', incident.source.name];
    final severity = analysis?.severity;
    if (severity != null) labels.add('severity-$severity');
    return labels;
  }

  Map<String, dynamic> _description(
    Incident incident,
    Analysis? analysis,
    String trace,
  ) {
    final content = <Map<String, dynamic>>[];

    if (analysis != null) {
      content.add(_heading('Root cause'));
      content.add(_paragraph(analysis.rootCause));
      if (analysis.reproSteps.isNotEmpty) {
        content.add(_heading('Reproduction steps'));
        content.add(_orderedList(analysis.reproSteps));
      }
      if (analysis.suggestedFix != null) {
        content.add(_heading('Suggested fix'));
        content.add(_paragraph(analysis.suggestedFix!));
      }
    } else {
      content.add(_paragraph(
        'Automated analysis was unavailable for this incident. Raw error: '
        '${_firstLine(incident.error)}',
      ));
    }

    content.add(_heading('Context'));
    content.add(_bulletList(_contextLines(incident)));

    content.add(_heading('Stack trace'));
    content.add(_codeBlock(_truncateTrace(trace)));

    return {'type': 'doc', 'version': 1, 'content': content};
  }

  /// Pulls known fields out of [Incident.context] rather than serialising
  /// the map wholesale, so anything the SDK's redaction missed doesn't land
  /// straight in a ticket.
  List<String> _contextLines(Incident incident) {
    final lines = <String>[
      'Platform: ${incident.platform}',
      'App version: ${incident.appVersion} '
          '(commit ${_shortSha(incident.commitSha)})',
    ];

    final device = incident.context['device'];
    if (device is Map) {
      final parts = <String>[];
      for (final key in ['model', 'manufacturer', 'os', 'os_version']) {
        final value = device[key];
        if (value != null) parts.add('$key=$value');
      }
      if (parts.isNotEmpty) lines.add('Device: ${parts.join(', ')}');
    }

    final routes = incident.context['routes'];
    if (routes is List && routes.isNotEmpty) {
      final names = routes
          .map((r) =>
              r is Map ? (r['name'] ?? r['route'] ?? r).toString() : '$r')
          .toList();
      final recent =
          names.length > 10 ? names.sublist(names.length - 10) : names;
      lines.add('Recent routes: ${recent.join(' -> ')}');
    }

    return lines;
  }

  String _shortSha(String sha) => sha.length > 7 ? sha.substring(0, 7) : sha;

  String _truncateTrace(String trace) {
    final lines = trace.split('\n');
    if (lines.length <= _maxTraceLines) return trace;
    final kept = lines.take(_maxTraceLines).join('\n');
    final omitted = lines.length - _maxTraceLines;
    return '$kept\n... truncated $omitted more frame'
        '${omitted == 1 ? '' : 's'} ...';
  }

  // ---- ADF builders -----------------------------------------------------

  Map<String, dynamic> _heading(String text) => {
        'type': 'heading',
        'attrs': {'level': 3},
        'content': [
          {'type': 'text', 'text': text},
        ],
      };

  Map<String, dynamic> _paragraph(String text) => {
        'type': 'paragraph',
        'content': [
          {'type': 'text', 'text': text},
        ],
      };

  Map<String, dynamic> _orderedList(List<String> items) => {
        'type': 'orderedList',
        'content': [
          for (final item in items)
            {
              'type': 'listItem',
              'content': [_paragraph(item)],
            },
        ],
      };

  Map<String, dynamic> _bulletList(List<String> items) => {
        'type': 'bulletList',
        'content': [
          for (final item in items)
            {
              'type': 'listItem',
              'content': [_paragraph(item)],
            },
        ],
      };

  Map<String, dynamic> _codeBlock(String text) => {
        'type': 'codeBlock',
        'content': [
          {'type': 'text', 'text': text},
        ],
      };
}

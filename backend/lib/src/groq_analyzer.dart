/// Turns a captured incident into an [Analysis] via an OpenAI-compatible
/// chat-completions endpoint (Groq today, Azure AI Foundry tomorrow).
/// Everything provider-specific is a constructor parameter, so swapping
/// provider is a config change, never a code change.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'contracts.dart';

class GroqAnalyzer implements IncidentAnalyzer {
  GroqAnalyzer({
    required String endpoint,
    required String authHeaderName,
    required String authHeaderValue,
    required String model,
    String? apiVersion,
    required Duration timeout,
    required http.Client client,
    required Log log,
  })  : _endpoint = endpoint,
        _authHeaderName = authHeaderName,
        _authHeaderValue = authHeaderValue,
        _model = model,
        _apiVersion = apiVersion,
        _log = log,
        _timeout = timeout,
        _client = client;

  final String _endpoint;
  final String _authHeaderName;
  final String _authHeaderValue;
  final String _model;
  final String? _apiVersion;
  final Duration _timeout;
  final http.Client _client;
  final Log _log;

  // Keeps the request small and cheap while keeping the highest-signal
  // fields: top stack frames and the most recent routes/breadcrumbs.
  static const int _maxStackTraceChars = 4000;
  static const int _maxRoutes = 15;
  static const int _maxBreadcrumbs = 20;

  static const Set<String> _validSeverities = {'blocker', 'major', 'minor'};

  @override
  Future<Analysis?> analyse(Incident incident, String symbolicatedTrace) async {
    // A broad catch: a slow/broken model must never delay ticket filing, and
    // an exception's toString() could echo the request back into a log line.
    try {
      final response = await _client
          .post(
            _requestUri(),
            headers: {
              'Content-Type': 'application/json',
              _authHeaderName: _authHeaderValue,
            },
            body: jsonEncode({
              'model': _model,
              'messages': [
                {'role': 'user', 'content': _buildPrompt(incident, symbolicatedTrace)},
              ],
            }),
          )
          .timeout(_timeout);

      if (response.statusCode != 200) {
        return _fail('http ${response.statusCode}: '
            '${response.body.substring(0, response.body.length.clamp(0, 200))}');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return _fail('response body was not a JSON object');
      }

      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) return _fail('no choices');

      final firstChoice = choices.first;
      final message = firstChoice is Map ? firstChoice['message'] : null;
      final content = message is Map ? message['content'] : null;
      if (content is! String || content.isEmpty) {
        return _fail('empty content; finish_reason='
            '${firstChoice is Map ? firstChoice['finish_reason'] : '?'}');
      }

      return _parseAnalysis(content, incident);
    } catch (e) {
      // Type only: the exception message can carry the request body and key.
      return _fail('threw ${e.runtimeType}');
    }
  }

  /// Every give-up path logs which, so a ticket with no root cause is
  /// traceable to a reason.
  Null _fail(String reason) {
    _log('[analyzer] no analysis: $reason');
    return null;
  }


  Uri _requestUri() {
    final base = Uri.parse(_endpoint);
    if (_apiVersion == null) return base;
    // Azure needs `?api-version=...`; Groq ignores the extra param.
    return base.replace(queryParameters: {
      ...base.queryParameters,
      'api-version': _apiVersion,
    });
  }

  String _buildPrompt(Incident incident, String symbolicatedTrace) {
    final trace = symbolicatedTrace.length > _maxStackTraceChars
        ? '${symbolicatedTrace.substring(0, _maxStackTraceChars)}\n...(truncated)'
        : symbolicatedTrace;

    final routes = _recentTail(incident.context['routes'], _maxRoutes);
    final breadcrumbs = _recentTail(incident.context['logs'], _maxBreadcrumbs);

    final buffer = StringBuffer()
      ..writeln(
        'You are a senior engineer triaging a production crash to write a Jira '
        'ticket. Read the incident evidence below and return ONLY a single '
        'JSON object as your entire response — no markdown code fences, no '
        'sentence before or after it.',
      )
      ..writeln(
        'Every key below is required. If the evidence is thin, say so in the '
        'value — never omit a key and never return a partial object.',
      )
      ..writeln('The JSON object must have exactly these keys:')
      ..writeln('  "title": one line, suitable as a Jira summary')
      ..writeln(
        '  "root_cause": explain why this happened for a developer who has '
        'never seen this code, grounded only in the evidence below',
      )
      ..writeln(
        '  "repro_steps": an array of strings — a step-by-step sequence to '
        'reproduce the crash, built from the route history below; do not '
        'invent steps it does not support',
      )
      ..writeln('  "severity": one of "blocker", "major", "minor"')
      ..writeln('  "suggested_fix": a concrete suggestion for what to change')
      ..writeln()
      ..writeln(
        'Do not echo the raw stack trace or user data verbatim into your '
        'answer, and do not invent facts that are not present in the input '
        'below.',
      )
      ..writeln()
      ..writeln('ERROR: ${incident.error}')
      ..writeln('ERROR CONTEXT: ${incident.errorContext ?? 'none'}')
      ..writeln('SOURCE: ${incident.source.name}')
      ..writeln('APP VERSION: ${incident.appVersion}')
      ..writeln('PLATFORM: ${incident.platform}');

    final stall = incident.context[uiStallContextKey];
    if (stall is Map && stall['duration_ms'] != null) {
      buffer.writeln(
        'UI STALL DURATION: ${stall['duration_ms']}ms (main isolate was '
        'blocked this long before capture)',
      );
    }

    buffer
      ..writeln()
      ..writeln('SYMBOLICATED STACK TRACE (may be truncated to the top frames):')
      ..writeln(trace)
      ..writeln()
      ..writeln(
        'ROUTE HISTORY (oldest to newest, most recent $_maxRoutes shown — use '
        'this to build repro_steps):',
      )
      ..writeln(routes.isEmpty ? 'none captured' : routes.join(' -> '))
      ..writeln()
      ..writeln('LOG BREADCRUMBS (most recent $_maxBreadcrumbs shown):')
      ..writeln(breadcrumbs.isEmpty ? 'none captured' : breadcrumbs.join('\n'));

    return buffer.toString();
  }

  /// Never touches `incident.context`'s `screenshot` — a base64 image that
  /// would blow the context window and cost if sent to the model.
  List<String> _recentTail(Object? raw, int max) {
    if (raw is! List) return const [];
    final items = raw.map((e) => e.toString()).toList();
    return items.length <= max ? items : items.sublist(items.length - max);
  }

  /// Models rename keys as readily as they omit them.
  static Object? _pick(Map<String, dynamic> json, List<String> names) {
    for (final name in names) {
      final value = json[name];
      if (value != null) return value;
    }
    return null;
  }

  Analysis? _parseAnalysis(String content, Incident incident) {
    final jsonText = _extractJsonObject(content);
    if (jsonText == null) {
      return _fail('no JSON object found in a ${content.length}-char reply');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (e) {
      return _fail('extracted text was not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      return _fail('parsed JSON was not an object');
    }

    // Only root cause is worth failing over: a title can be built from the
    // error, and missing repro steps cost a section, not the whole analysis.
    final rootCause = _pick(decoded, ['root_cause', 'rootCause', 'cause']);
    if (rootCause is! String || rootCause.trim().isEmpty) {
      return _fail('missing root_cause');
    }

    final titleRaw = _pick(decoded, ['title', 'summary', 'headline']);
    final title = titleRaw is String && titleRaw.trim().isNotEmpty
        ? titleRaw.trim()
        : '${incident.error} (${incident.platform})';

    final reproStepsRaw =
        _pick(decoded, ['repro_steps', 'reproSteps', 'steps', 'reproduction_steps']);
    final reproSteps = reproStepsRaw is List
        ? reproStepsRaw
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList()
        : <String>[];

    final severityRaw = _pick(decoded, ['severity', 'priority']);
    final severity =
        severityRaw is String && _validSeverities.contains(severityRaw.toLowerCase())
            ? severityRaw.toLowerCase()
            : null;
    final suggestedFix = _pick(decoded, ['suggested_fix', 'suggestedFix', 'fix']);

    return Analysis(
      title: title,
      rootCause: rootCause,
      reproSteps: reproSteps,
      severity: severity,
      suggestedFix: suggestedFix is String ? suggestedFix : null,
    );
  }

  /// Pulls a JSON object out of a chat completion's free-form text (models
  /// wrap it in fences or ramble ahead of it). Tracks string/escape state
  /// rather than brace-counting alone, which would misfire on a `}` inside a
  /// quoted string.
  String? _extractJsonObject(String content) {
    final fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(content);
    final text = fenced != null ? fenced.group(1)! : content;

    final start = text.indexOf('{');
    if (start == -1) return null;

    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return null;
  }
}

import 'dart:collection';
import 'dart:convert';

import 'collector.dart';

/// Header values redacted with no opt-out, matched case-insensitively.
const kSensitiveHeaders = {
  'authorization',
  'proxy-authorization',
  'cookie',
  'set-cookie',
  'x-api-key',
  'x-auth-token',
  'x-access-token',
  'x-session-token',
  'x-csrf-token',
};

/// JSON body field names whose values are redacted when opt-in body capture
/// is on.
const _kSensitiveBodyKeys = {
  'password',
  'token',
  'secret',
  'apikey',
  'api_key',
  'authorization',
  'cookie',
};

/// Bodies larger than this are neither shape-extracted nor captured. Public
/// so [IncidentHttpClient] can cap how much of a response it buffers.
const kMaxInspectBytes = 256 * 1024;

/// Recursion cap for [_shapeOf] / [_redactJsonValues] — a byte-size cap on
/// the body doesn't bound nesting depth (`"[[[[...]]]]"` fits in a few KB).
const _kMaxJsonDepth = 20;

/// Minimum key count before [_looksLikeDictionary] treats a map as one —
/// below this, a shared value shape is as likely coincidence
/// (`{"width": 10, "height": 20}`) as a real dictionary.
const _kDictionaryMinKeys = 4;

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final _hexDigestPattern = RegExp(r'^[0-9a-fA-F]{16,}$');
final _opaqueIdPrefixPattern = RegExp(r'^([a-z]{1,8})_([A-Za-z0-9]{6,})$');

/// A key that is lexically PII-shaped on its own (email, UUID, hex digest,
/// an opaque prefixed id like `cus_Nq8sT2bXyZ`). Second line of defence on
/// top of [_looksLikeDictionary]: a plain username is lexically identical
/// to a field name.
bool _looksLikePiiKey(String key) {
  if (key.length > 40) return true;
  if (key.contains('@')) return true;
  if (_uuidPattern.hasMatch(key)) return true;
  if (_hexDigestPattern.hasMatch(key)) return true;
  final opaqueMatch = _opaqueIdPrefixPattern.firstMatch(key);
  if (opaqueMatch != null) {
    // A digit in the suffix separates `cus_Nq8sT2bXyZ` from `los_angeles`.
    final suffix = opaqueMatch.group(2)!;
    if (suffix.contains(RegExp(r'[0-9]'))) return true;
  }
  return false;
}

String _shapeKind(dynamic shape) =>
    shape is Map ? 'map' : (shape is List ? 'list' : 'scalar');

/// True when a map's keys look like data (ids/emails) rather than schema —
/// key text can't tell them apart, so this compares value shapes instead:
/// a dictionary's entries are uniformly the same kind.
///
/// Deliberately over-collapses: losing field names beats leaking keys.
bool _looksLikeDictionary(int keyCount, List<dynamic> valueShapes) {
  if (keyCount < _kDictionaryMinKeys) return false;
  // A null entry is an absent record, not a differently-kinded one; letting
  // it veto the collapse is how a 2-maps-2-nulls map leaked its keys.
  final present = valueShapes.where((s) => s != 'Null').toList();
  if (present.isEmpty) return true;
  // Majority, not unanimous: a partial-failure response with one
  // differently-shaped entry is still a dictionary.
  if (_majorityKindCount(present) * 2 > present.length) return true;
  // Kinds alone tie on an even split; repeated shapes are the other
  // dictionary tell — a record's fields each have their own shape.
  return _distinctShapes(present) * 2 <= present.length;
}

/// Distinct shapes in [shapes], compared structurally. Every scalar counts
/// as one shape — counting them separately inflated the tally and misread
/// scalar dictionaries as records.
int _distinctShapes(List<dynamic> shapes) => shapes
    .map((s) => s is Map || s is List ? _canonicalShape(s) : 'scalar')
    .toSet()
    .length;

/// Order-independent shape rendering — comparing raw `jsonEncode` output
/// would call same-shaped entries distinct whenever field order differs.
String _canonicalShape(dynamic shape) {
  if (shape is Map) {
    final keys = shape.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '$k:${_canonicalShape(shape[k])}').join(',')}}';
  }
  if (shape is List) {
    final parts = shape.map(_canonicalShape).toList()..sort();
    return '[${parts.join(',')}]';
  }
  return '$shape';
}

int _majorityKindCount(List<dynamic> shapes) {
  final counts = <String, int>{};
  for (final s in shapes) {
    final kind = _shapeKind(s);
    counts[kind] = (counts[kind] ?? 0) + 1;
  }
  return counts.values.reduce((a, b) => a > b ? a : b);
}

/// The most common kind among [shapes] — the representative is drawn from
/// this group so an outlier isn't shown as if it were typical.
String _majorityKind(List<dynamic> shapes) {
  final counts = <String, int>{};
  for (final s in shapes) {
    final kind = _shapeKind(s);
    counts[kind] = (counts[kind] ?? 0) + 1;
  }
  var best = _shapeKind(shapes.first);
  var bestCount = 0;
  counts.forEach((kind, count) {
    if (count > bestCount) {
      bestCount = count;
      best = kind;
    }
  });
  return best;
}

/// Representative shape for a collapsed dictionary, ignoring nulls — else
/// a few null entries could out-vote a real record's shape.
dynamic _representativeShape(List<dynamic> valueShapes) {
  final present = valueShapes.where((s) => s != 'Null').toList();
  if (present.isEmpty) return 'Null';
  final kind = _majorityKind(present);
  final ofKind = present.where((s) => _shapeKind(s) == kind).toList();
  return _majorityShape(ofKind).shape;
}

/// Most common shape among [valueShapes] and how many share it — used as
/// the representative when collapsing a dictionary.
({dynamic shape, int count}) _majorityShape(List<dynamic> valueShapes) {
  final counts = <String, int>{};
  for (final s in valueShapes) {
    final sig = _shapeSignature(s);
    counts[sig] = (counts[sig] ?? 0) + 1;
  }
  var bestSignature = _shapeSignature(valueShapes.first);
  var bestCount = 0;
  counts.forEach((sig, count) {
    if (count > bestCount) {
      bestCount = count;
      bestSignature = sig;
    }
  });
  return (
    shape: valueShapes.firstWhere((s) => _shapeSignature(s) == bestSignature),
    count: bestCount,
  );
}

/// Canonical shape for equality (Dart's `==` on map/list literals is
/// identity-based). Leaf-insensitive: every scalar/list collapses to `*`
/// so a nullable or optional field doesn't make two entries look different.
String _shapeSignature(dynamic shape) {
  if (shape is Map) {
    final keys = shape.keys.map((k) => k.toString()).toList()..sort();
    final parts = keys.map((k) => '$k:${_shapeSignature(shape[k])}');
    return '{${parts.join(',')}}';
  }
  if (shape is List) return '[*]';
  return '*';
}

/// A path segment that reads as data (email, UUID, hex digest, opaque
/// token) rather than route shape. A short numeric id and an ordinary
/// hyphenated word (`subscription-management`) are left alone.
bool _looksLikeOpaqueSegment(String segment) {
  if (segment.length < 20) return false;
  if (!RegExp(r'^[A-Za-z0-9_.]+$').hasMatch(segment)) return false;
  // No hyphen + a digit or mixed case: separates a token/JWT chunk from a
  // long plain word like "internationalization".
  final hasDigit = segment.contains(RegExp(r'[0-9]'));
  final hasUpper = segment.contains(RegExp(r'[A-Z]'));
  final hasLower = segment.contains(RegExp(r'[a-z]'));
  return hasDigit || (hasUpper && hasLower);
}

String _redactPathSegment(String segment) {
  if (segment.contains('@')) return '[redacted]';
  if (_uuidPattern.hasMatch(segment)) return '[redacted]';
  if (_hexDigestPattern.hasMatch(segment)) return '[redacted]';
  if (_looksLikeOpaqueSegment(segment)) return '[redacted]';
  return segment;
}

/// Records the last [maxEntries] HTTP requests made through
/// [IncidentHttpClient] — the "what was the app talking to" trail.
///
/// Query values, the URL fragment, userinfo credentials,
/// [kSensitiveHeaders], and PII-shaped path segments/JSON keys are redacted
/// with no opt-out; bodies are never recorded unless [captureBody] is set.
///
/// Known limitation: a small object (below [_kDictionaryMinKeys] entries)
/// keyed by non-PII-shaped data (e.g. plain usernames) still has its keys
/// emitted — see [_looksLikeDictionary].
class NetworkCollector {
  NetworkCollector({
    this.maxEntries = 20,
    this.captureBody = false,
    this.maxBodyBytes = 2 * 1024,
  });

  final int maxEntries;

  /// Off by default: capturing any part of a body is an explicit host-app
  /// choice, never the SDK's default behaviour.
  final bool captureBody;

  final int maxBodyBytes;

  final _entries = Queue<Map<String, dynamic>>();

  /// This buffer's output, registered under the name `network`.
  IncidentCollector get collector => (
        name: 'network',
        collect: () => {
          'requests': _entries.toList(growable: false),
        },
      );

  /// Called by [IncidentHttpClient] after the real network call finishes —
  /// never from the crash path.
  void record({
    required String method,
    required Uri url,
    Map<String, String> requestHeaders = const {},
    int? requestBytes,
    List<int>? requestBodyBytes,
    String? requestContentType,
    int? statusCode,
    Map<String, String> responseHeaders = const {},
    int? responseBytes,
    List<int>? responseBodyBytes,
    String? responseContentType,
    required Duration duration,
    String? error,
  }) {
    final entry = <String, dynamic>{
      'method': method,
      'url': _redactUrl(url).toString(),
      'requestHeaders': _redactHeaders(requestHeaders),
      'durationMs': duration.inMilliseconds,
      'at': DateTime.now().toIso8601String(),
    };
    if (requestBytes != null) entry['requestBytes'] = requestBytes;
    if (statusCode != null) entry['statusCode'] = statusCode;
    if (error != null) entry['error'] = error;
    if (responseHeaders.isNotEmpty) {
      entry['responseHeaders'] = _redactHeaders(responseHeaders);
    }
    if (responseBytes != null) entry['responseBytes'] = responseBytes;

    // Extracted regardless of captureBody — it's never a value, just shape.
    final responseShape = _shapeOfJsonBody(
      responseContentType,
      responseBodyBytes,
    );
    if (responseShape != null) entry['responseShape'] = responseShape;

    if (captureBody) {
      final capturedRequest = _captureBody(requestContentType, requestBodyBytes);
      if (capturedRequest != null) entry['requestBody'] = capturedRequest;
      final capturedResponse =
          _captureBody(responseContentType, responseBodyBytes);
      if (capturedResponse != null) entry['responseBody'] = capturedResponse;
    }

    _entries.add(entry);
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
  }

  Map<String, String> _redactHeaders(Map<String, String> headers) => {
        for (final e in headers.entries)
          e.key: kSensitiveHeaders.contains(e.key.toLowerCase())
              ? '[redacted]'
              : e.value,
      };

  Uri _redactUrl(Uri url) {
    var result = url;
    if (url.userInfo.isNotEmpty) {
      result = result.replace(userInfo: 'redacted');
    }
    if (url.queryParameters.isNotEmpty) {
      result = result.replace(
        queryParameters: {
          for (final k in url.queryParameters.keys) k: '[redacted]',
        },
      );
    }
    if (url.pathSegments.isNotEmpty) {
      result = result.replace(
        pathSegments: url.pathSegments.map(_redactPathSegment).toList(),
      );
    }
    if (url.fragment.isNotEmpty) {
      // Fragments carry OAuth tokens and SPA routes keyed by user data;
      // parsing them leaked twice, so nothing here is preserved.
      result = result.replace(fragment: 'redacted');
    }
    return result;
  }


  /// Size-capped, best-effort capture — only called when [captureBody] is
  /// on. A non-JSON body is truncated but not otherwise inspected.
  String? _captureBody(String? contentType, List<int>? bodyBytes) {
    if (bodyBytes == null || bodyBytes.isEmpty) return null;
    if (bodyBytes.length > kMaxInspectBytes) return null;
    String text;
    try {
      text = utf8.decode(bodyBytes);
    } catch (_) {
      return null;
    }
    if (_isJson(contentType)) {
      try {
        final redacted = _redactJsonValues(jsonDecode(text), 0);
        text = jsonEncode(redacted);
      } catch (_) {
        // Not actually valid JSON despite the content type.
      }
    }
    return text.length > maxBodyBytes ? text.substring(0, maxBodyBytes) : text;
  }

  /// Same dictionary-vs-record rule as [_shapeOf], applied to opt-in body
  /// capture.
  dynamic _redactJsonValues(dynamic value, int depth) {
    if (depth > _kMaxJsonDepth) return '[redacted:max-depth]';
    if (value is Map) {
      if (value.isEmpty) return <String, dynamic>{};
      final entries = value.entries.toList();
      final valueShapes = [for (final e in entries) _shapeOf(e.value, depth + 1)];
      if (_looksLikeDictionary(entries.length, valueShapes)) {
        return {'<dynamic>': '[redacted]', '_keyCount': entries.length};
      }
      var redactedIndex = 0;
      final result = <String, dynamic>{};
      for (final e in entries) {
        final key = e.key.toString();
        if (_looksLikePiiKey(key)) {
          result['<redacted-key-${redactedIndex++}>'] = '[redacted]';
        } else if (_kSensitiveBodyKeys.contains(key.toLowerCase())) {
          result[key] = '[redacted]';
        } else {
          result[key] = _redactJsonValues(e.value, depth + 1);
        }
      }
      return result;
    }
    if (value is List) {
      return value.map((v) => _redactJsonValues(v, depth + 1)).toList();
    }
    return value;
  }

  Map<String, dynamic>? _shapeOfJsonBody(
    String? contentType,
    List<int>? bodyBytes,
  ) {
    if (!_isJson(contentType)) return null;
    if (bodyBytes == null || bodyBytes.isEmpty) return null;
    if (bodyBytes.length > kMaxInspectBytes) return null;
    try {
      final decoded = jsonDecode(utf8.decode(bodyBytes));
      final shape = _shapeOf(decoded, 0);
      return shape is Map<String, dynamic> ? shape : {'_root': shape};
    } catch (_) {
      return null;
    }
  }

  /// Key names and value *types*, recursively — never a value. [depth] caps
  /// nesting so a pathological response can't stack-overflow this.
  dynamic _shapeOf(dynamic value, int depth) {
    if (depth > _kMaxJsonDepth) return 'MaxDepthExceeded';
    if (value == null) return 'Null';
    if (value is bool) return 'bool';
    if (value is int) return 'int';
    if (value is double) return 'double';
    if (value is String) return 'String';
    if (value is List) {
      // Only the first element's shape is inspected.
      return value.isEmpty ? <String>[] : [_shapeOf(value.first, depth + 1)];
    }
    if (value is Map) {
      if (value.isEmpty) return <String, dynamic>{};
      final entries = value.entries.toList();
      final valueShapes = [
        for (final e in entries) _shapeOf(e.value, depth + 1),
      ];
      if (_looksLikeDictionary(entries.length, valueShapes)) {
        return {
          '<dynamic>': _representativeShape(valueShapes),
          '_keyCount': entries.length,
        };
      }
      var redactedIndex = 0;
      final result = <String, dynamic>{};
      for (var i = 0; i < entries.length; i++) {
        final key = entries[i].key.toString();
        result[_looksLikePiiKey(key) ? '<redacted-key-${redactedIndex++}>' : key] =
            valueShapes[i];
      }
      return result;
    }
    return value.runtimeType.toString();
  }

  bool _isJson(String? contentType) =>
      contentType != null && contentType.toLowerCase().contains('json');
}

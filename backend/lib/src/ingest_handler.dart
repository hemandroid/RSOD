import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'contracts.dart';
import 'pipeline.dart';

/// HTTP surface: `POST /ingest` and `GET /health`. Kept apart from
/// `bin/server.dart` so routing and auth can be tested without binding a port.
class IngestHandler {
  IngestHandler({
    required String appToken,
    required this.pipeline,
    required this.log,
    this.maxBodyBytes = 8 * 1024 * 1024,
    this.maxInFlight = 32,
  }) : _appToken = appToken;

  final String _appToken;
  final IncidentPipeline pipeline;
  final Log log;

  final int maxBodyBytes;

  /// Every accepted incident spends a model call and a Jira write; without a
  /// ceiling, one crash-looping app drains the quota. 429 tells the SDK's
  /// uploader to back off.
  final int maxInFlight;

  /// Completes when accepted incidents have been processed; used by tests
  /// and shutdown.
  Future<void> get idle => Future.wait(_inFlight.toList());
  final Set<Future<void>> _inFlight = {};

  Handler get handler => (Request request) async {
        if (request.method == 'GET' && request.url.path == 'health') {
          return Response.ok('ok');
        }
        if (request.method != 'POST' || request.url.path != 'ingest') {
          return Response.notFound('not found');
        }
        if (!_authorised(request.headers['authorization'])) {
          return Response.forbidden('invalid token');
        }

        final List<Incident> incidents;
        try {
          final body = await _read(request);
          if (body == null) {
            return Response(413, body: 'payload too large');
          }
          incidents = _parse(body);
        } on FormatException catch (e) {
          return Response.badRequest(body: 'malformed payload: ${e.message}');
        }

        if (_inFlight.length >= maxInFlight) {
          log('shedding ${incidents.length} incident(s): $maxInFlight in flight');
          return Response(429, body: 'busy', headers: {'retry-after': '30'});
        }

        // Ack before the slow work: the SDK retries anything not 2xx, so
        // waiting on Jira's latency here would duplicate the incident.
        _spawn(incidents);
        return Response.ok('accepted ${incidents.length}');
      };

  void _spawn(List<Incident> incidents) {
    for (final incident in incidents) {
      late final Future<void> work;
      work = Future(() => pipeline.process(incident)).catchError((Object e) {
        log('pipeline threw for ${incident.id}: $e');
      }).whenComplete(() => _inFlight.remove(work));
      _inFlight.add(work);
    }
  }

  /// Constant-time: a token compared with `==` leaks length and prefix to
  /// anyone who can measure the response.
  bool _authorised(String? header) {
    const prefix = 'Bearer ';
    if (header == null || !header.startsWith(prefix)) return false;
    final presented = header.substring(prefix.length);
    if (presented.length != _appToken.length) return false;
    var diff = 0;
    for (var i = 0; i < presented.length; i++) {
      diff |= presented.codeUnitAt(i) ^ _appToken.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<String?> _read(Request request) async {
    final declared = request.contentLength;
    if (declared != null && declared > maxBodyBytes) return null;

    final chunks = <List<int>>[];
    var total = 0;
    await for (final chunk in request.read()) {
      total += chunk.length;
      if (total > maxBodyBytes) return null;
      chunks.add(chunk);
    }
    try {
      return utf8.decode(chunks.expand((c) => c).toList());
    } on FormatException catch (e) {
      // Replacing bad bytes would hand the parser a subtly wrong incident.
      throw FormatException('body was not valid UTF-8: ${e.message}');
    }
  }

  /// A single object is accepted too, so a hand-written `curl` doesn't need
  /// the brackets.
  List<Incident> _parse(String body) {
    final decoded = jsonDecode(body);
    final raw = switch (decoded) {
      List<dynamic> list => list,
      Map<String, dynamic> one => [one],
      _ => throw const FormatException('expected a JSON array or object'),
    };
    final out = <Incident>[];
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('array entries must be objects');
      }
      try {
        out.add(Incident.fromJson(entry));
      } on Object catch (e) {
        // One malformed incident in a batch must not discard the rest.
        log('skipping unparsable incident: $e');
      }
    }
    if (out.isEmpty) throw const FormatException('no usable incidents');
    return out;
  }
}

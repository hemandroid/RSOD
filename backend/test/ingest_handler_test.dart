import 'dart:convert';

import 'package:incident_backend/src/ingest_handler.dart';
import 'package:incident_backend/src/pipeline.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'fakes.dart';

const _token = 'a-token-of-some-length';

Map<String, dynamic> wire({
  String id = 'inc-1',
  String source = 'flutterError',
}) =>
    {
      'id': id,
      'captured_at': '2026-09-20T09:14:22.000Z',
      'source': source,
      'error': 'Bad state: No element',
      'stack_trace': 'raw trace',
      'app_version': '1.0.0',
      'commit_sha': 'abc1234',
      'platform': 'android',
      'context': <String, dynamic>{},
    };

void main() {
  late FakeFiler filer;
  late FakeNotifier notifier;
  late List<String> logs;
  late IngestHandler subject;

  IngestHandler build({int maxBodyBytes = 8 * 1024 * 1024}) => IngestHandler(
        appToken: _token,
        log: logs.add,
        maxBodyBytes: maxBodyBytes,
        pipeline: IncidentPipeline(
          symbolicator: FakeSymbolicator(),
          analyzer: FakeAnalyzer(),
          filer: filer,
          notifier: notifier,
          dedupe: FakeDedupe(),
          fingerprint: (i) => i.id,
          log: logs.add,
        ),
      );

  setUp(() {
    filer = FakeFiler();
    notifier = FakeNotifier();
    logs = [];
    subject = build();
  });

  Future<Response> post(Object? body, {String? token = _token}) async =>
      await subject.handler(Request(
        'POST',
        Uri.parse('http://localhost/ingest'),
        headers: {
          if (token != null) 'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: body is String ? body : jsonEncode(body),
      ));

  test('health needs no token', () async {
    final res = await subject.handler(
      Request('GET', Uri.parse('http://localhost/health')),
    );
    expect(res.statusCode, 200);
  });

  test('a missing token is refused', () async {
    expect((await post([wire()], token: null)).statusCode, 403);
    expect(filer.filed, isEmpty);
  });

  test('a wrong token of the same length is refused', () async {
    final wrong = 'b' * _token.length;
    expect((await post([wire()], token: wrong)).statusCode, 403);
    expect(filer.filed, isEmpty);
  });

  test('a valid batch is accepted and every incident processed', () async {
    final res = await post([wire(id: 'a'), wire(id: 'b')]);
    expect(res.statusCode, 200);

    await subject.idle;
    expect(filer.filed.map((f) => f.incident.id), ['a', 'b']);
    expect(notifier.sent, hasLength(2));
  });

  test('a bare object is accepted, not just an array', () async {
    expect((await post(wire())).statusCode, 200);
    await subject.idle;
    expect(filer.filed, hasLength(1));
  });

  test('malformed JSON is rejected without reaching the pipeline', () async {
    expect((await post('{not json')).statusCode, 400);
    expect(filer.filed, isEmpty);
  });

  test('one unparsable entry does not discard the rest of the batch',
      () async {
    final res = await post([
      wire(id: 'good'),
      {'id': 'broken'},
    ]);
    expect(res.statusCode, 200);

    await subject.idle;
    expect(filer.filed.map((f) => f.incident.id), ['good']);
    expect(logs.any((l) => l.contains('skipping unparsable')), isTrue);
  });

  test('an unknown source degrades rather than dropping the incident',
      () async {
    await post([wire(source: 'somethingNewerShipped')]);
    await subject.idle;
    expect(filer.filed.single.incident.source.name, 'manual');
  });

  test('an oversized body is refused', () async {
    subject = build(maxBodyBytes: 64);
    expect((await post([wire()])).statusCode, 413);
    expect(filer.filed, isEmpty);
  });

  test('an unknown route is a 404', () async {
    final res = await subject.handler(
      Request('POST', Uri.parse('http://localhost/nope')),
    );
    expect(res.statusCode, 404);
  });
}

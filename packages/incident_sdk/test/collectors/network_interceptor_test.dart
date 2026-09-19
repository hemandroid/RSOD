import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:incident_sdk/src/collectors/network_collector.dart';
import 'package:incident_sdk/src/collectors/network_interceptor.dart';

List<Map<String, dynamic>> _requests(NetworkCollector c) =>
    (c.collector.collect()['requests'] as List).cast<Map<String, dynamic>>();

void main() {
  test('forwards the request to inner and returns its response unchanged',
      () async {
    final collector = NetworkCollector();
    final mock = MockClient((request) async {
      return http.Response(
        jsonEncode({'id': 1}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = IncidentHttpClient(collector, inner: mock);

    final response =
        await client.get(Uri.parse('https://api.example.com/user?token=abc'));

    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), {'id': 1});
  });

  test('records method, status and response shape, with no real network',
      () async {
    final collector = NetworkCollector();
    final mock = MockClient((request) async {
      return http.Response(
        jsonEncode({'name': 'Jane', 'email': 'jane@example.com'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = IncidentHttpClient(collector, inner: mock);

    await client.get(Uri.parse('https://api.example.com/user?token=secret'));

    final entry = _requests(collector).single;
    expect(entry['method'], 'GET');
    expect(entry['statusCode'], 200);
    expect(entry['responseShape'], {'name': 'String', 'email': 'String'});

    final dumped = jsonEncode(entry);
    expect(dumped, isNot(contains('jane@example.com')));
    expect(dumped, isNot(contains('token=secret')));
  });

  test('redacts the authorization header sent on the request', () async {
    final collector = NetworkCollector();
    final mock = MockClient((request) async => http.Response('', 200));
    final client = IncidentHttpClient(collector, inner: mock);

    await client.get(
      Uri.parse('https://api.example.com/me'),
      headers: {'Authorization': 'Bearer top-secret'},
    );

    final entry = _requests(collector).single;
    final headers = entry['requestHeaders'] as Map<String, dynamic>;
    expect(headers['Authorization'], '[redacted]');
    expect(jsonEncode(entry), isNot(contains('top-secret')));
  });

  test('records a failed request without a status code, then rethrows',
      () async {
    final collector = NetworkCollector();
    final mock = MockClient((request) async => throw Exception('boom'));
    final client = IncidentHttpClient(collector, inner: mock);

    await expectLater(
      client.get(Uri.parse('https://api.example.com/down')),
      throwsA(isA<Exception>()),
    );

    final entry = _requests(collector).single;
    expect(entry.containsKey('statusCode'), isFalse);
    expect(entry['error'], contains('boom'));
  });

  test('does not capture bodies unless the collector opts in', () async {
    final collector = NetworkCollector();
    final mock = MockClient((request) async => http.Response(
          jsonEncode({'password': 'hunter2'}),
          200,
          headers: {'content-type': 'application/json'},
        ));
    final client = IncidentHttpClient(collector, inner: mock);

    await client.get(Uri.parse('https://api.example.com/secret'));

    expect(_requests(collector).single.containsKey('responseBody'), isFalse);
  });

  test(
      'does not buffer the whole response before returning — headers arrive '
      'before the body does', () async {
    final collector = NetworkCollector();
    final bodyController = StreamController<List<int>>();
    final mock = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(
        bodyController.stream,
        200,
        headers: {'content-type': 'text/plain'},
      );
    });
    final client = IncidentHttpClient(collector, inner: mock);

    // If `send()` buffered the full body with `toBytes()` before returning,
    // this would hang until the timeout, because bodyController is never
    // closed until after the response is checked below.
    final response = await client
        .send(http.Request('GET', Uri.parse('https://api.example.com/stream')))
        .timeout(const Duration(seconds: 2));
    expect(response.statusCode, 200);

    final chunks = <List<int>>[];
    final sub = response.stream.listen(chunks.add);
    bodyController.add(utf8.encode('hello '));
    await Future<void>.delayed(Duration.zero);
    expect(chunks, isNotEmpty,
        reason: 'a chunk sent after the response was returned must still '
            'reach the real caller — the body streams through, it is not '
            'replayed from a full buffer');

    bodyController.add(utf8.encode('world'));
    await bodyController.close();
    await sub.asFuture<void>();

    expect(utf8.decode(chunks.expand((c) => c).toList()), 'hello world');

    final entry = _requests(collector).single;
    expect(entry['responseBytes'], 'hello world'.length);
  });

  test(
      'does not subscribe to the underlying response stream until the '
      'caller listens, matching a plain http.Client', () async {
    final collector = NetworkCollector();
    final bodyController = StreamController<List<int>>();
    final mock = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(bodyController.stream, 200);
    });
    final client = IncidentHttpClient(collector, inner: mock);

    final response = await client
        .send(http.Request('GET', Uri.parse('https://api.example.com/lazy')));

    expect(bodyController.hasListener, isFalse,
        reason: 'a caller that has not listened yet must not have caused '
            'the real network stream to be read — eager subscription would '
            'buffer an unbounded amount of data with nobody consuming it, '
            'which a plain http.Client never does');

    final sub = response.stream.listen((_) {});
    expect(bodyController.hasListener, isTrue);

    await sub.cancel();
    await bodyController.close();
  });

  test(
      'still records an entry, marked as cancelled, if the caller cancels '
      'mid-body', () async {
    final collector = NetworkCollector();
    final bodyController = StreamController<List<int>>();
    final mock = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(
        bodyController.stream,
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = IncidentHttpClient(collector, inner: mock);

    final response = await client.send(
      http.Request('GET', Uri.parse('https://api.example.com/cancel-me')),
    );
    final sub = response.stream.listen((_) {});
    bodyController.add(utf8.encode('{"partial":'));
    await Future<void>.delayed(Duration.zero);

    await sub.cancel();
    await Future<void>.delayed(Duration.zero);

    final entry = _requests(collector).single;
    expect(entry['statusCode'], 200,
        reason: 'headers arrived successfully before the cancel — that '
            'status is still worth recording');
    expect(entry['error'], contains('cancel'));
    expect(entry.containsKey('responseBody'), isFalse);
    expect(entry.containsKey('responseShape'), isFalse);

    await bodyController.close();
  });
}

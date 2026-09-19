import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:incident_sdk/src/upload/transport.dart';

/// Hand-rolled fake headers: `HttpIncidentTransport` only ever calls [set]
/// (on the request) and [value] (on the response, for `Retry-After`), so
/// only those need real behaviour. `noSuchMethod` covers the rest of the
/// large `HttpHeaders` interface without a mocking package.
class _FakeHeaders implements HttpHeaders {
  _FakeHeaders([Map<String, String>? initial])
      : _values = {
          for (final entry in (initial ?? const {}).entries)
            entry.key.toLowerCase(): entry.value,
        };

  final Map<String, String> _values;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => _values[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A response with a fixed status, body and headers — no socket. Extends
/// [Stream] (rather than faking `listen` from scratch) so the real `Stream`
/// mixin gives `transform`/`join` for free, matching how the transport reads
/// the body.
class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, {String body = '', Map<String, String>? headers})
      : _body = Stream.value(utf8.encode(body)),
        headers = _FakeHeaders(headers);

  @override
  final int statusCode;
  @override
  final HttpHeaders headers;
  final Stream<List<int>> _body;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _body.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A request that records nothing and just hands back whatever [onClose]
/// produces — the transport only calls `headers.set`, `write` and `close`.
class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.onClose);

  final Future<HttpClientResponse> Function() onClose;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  void write(Object? object) {}

  @override
  Future<HttpClientResponse> close() => onClose();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A client whose one real behaviour is `postUrl` — enough to test every
/// status-code branch in `HttpIncidentTransport.send` without ever opening a
/// socket, using the injection point the class already exposes for exactly
/// this purpose.
class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._onPostUrl);

  final Future<HttpClientRequest> Function(Uri url) _onPostUrl;

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _onPostUrl(url);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

HttpIncidentTransport _transport(
  Future<HttpClientResponse> Function() respond,
) =>
    HttpIncidentTransport(
      endpoint: Uri.parse('https://incidents.example.com/ingest'),
      appToken: 'token-123',
      client: _FakeHttpClient((url) async => _FakeRequest(respond)),
    );

void main() {
  test('PermanentUploadFailure carries its reason', () {
    const failure = PermanentUploadFailure('HTTP 401: bad token');
    expect(failure.reason, 'HTTP 401: bad token');
    expect(failure.toString(), contains('bad token'));
  });

  test('HttpIncidentTransport is constructed from endpoint and token', () {
    final transport = HttpIncidentTransport(
      endpoint: Uri.parse('https://incidents.example.com/ingest'),
      appToken: 'token-123',
    );
    expect(transport.endpoint.toString(),
        'https://incidents.example.com/ingest');
    expect(transport.appToken, 'token-123');
  });

  test('2xx is a confirmed success', () async {
    final transport = _transport(() async => _FakeResponse(200));
    await expectLater(transport.send([]), completes);
  });

  test('400 is permanent: a malformed payload will not fix itself on retry',
      () async {
    final transport =
        _transport(() async => _FakeResponse(400, body: 'bad payload'));
    await expectLater(
      transport.send([]),
      throwsA(isA<PermanentUploadFailure>()
          .having((e) => e.reason, 'reason', contains('bad payload'))),
    );
  });

  test('401 is permanent: the brief treats a rejected token as unrecoverable',
      () async {
    final transport = _transport(() async => _FakeResponse(401));
    await expectLater(
      transport.send([]),
      throwsA(isA<PermanentUploadFailure>()),
    );
  });

  test('408 is transient: a timeout means try again, not "this is broken"',
      () async {
    final transport = _transport(() async => _FakeResponse(408));
    await expectLater(
      transport.send([]),
      throwsA(isA<HttpException>()),
    );
  });

  test('429 is transient and carries the Retry-After header', () async {
    final transport = _transport(
      () async => _FakeResponse(429, headers: {'retry-after': '5'}),
    );
    await expectLater(
      transport.send([]),
      throwsA(isA<RateLimited>()
          .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 5))),
    );
  });

  test('a negative Retry-After is floored at zero, not honoured as-is',
      () async {
    // A backend answering `-1` on every 429 would otherwise produce a
    // zero-delay retry loop: the uploader's own cap only clamps from above.
    final transport = _transport(
      () async => _FakeResponse(429, headers: {'retry-after': '-1'}),
    );

    await expectLater(
      transport.send([]),
      throwsA(isA<RateLimited>()
          .having((e) => e.retryAfter, 'retryAfter', Duration.zero)),
    );
  });

  test('429 without a Retry-After header still classifies as rate limited',
      () async {
    final transport = _transport(() async => _FakeResponse(429));
    await expectLater(
      transport.send([]),
      throwsA(isA<RateLimited>().having((e) => e.retryAfter, 'retryAfter', isNull)),
    );
  });

  test('413 signals a too-large payload rather than a permanent rejection',
      () async {
    final transport = _transport(() async => _FakeResponse(413));
    await expectLater(
      transport.send([]),
      throwsA(isA<PayloadTooLargeFailure>()),
    );
  });

  test('500 is transient, not a permanent rejection', () async {
    final transport = _transport(() async => _FakeResponse(500));
    await expectLater(
      transport.send([]),
      throwsA(isA<HttpException>()),
    );
  });

  test('a network-level failure propagates for the uploader to retry',
      () async {
    final transport = HttpIncidentTransport(
      endpoint: Uri.parse('https://incidents.example.com/ingest'),
      appToken: 'token-123',
      client: _FakeHttpClient((url) async => throw const SocketException('offline')),
    );
    await expectLater(transport.send([]), throwsA(isA<SocketException>()));
  });
}

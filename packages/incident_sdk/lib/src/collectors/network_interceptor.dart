import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'network_collector.dart';

/// A drop-in `http.Client` that records every request into a
/// [NetworkCollector] before forwarding it unchanged to [inner].
///
/// This is the entire adoption story: replace `http.Client()` with
/// `IncidentHttpClient(collector, inner: http.Client())` wherever the app
/// constructs its client, and every existing call site — `client.get(...)`,
/// `client.post(...)`, etc. — keeps working with no other change, because
/// those methods are all implemented in terms of [send] on the base class.
///
/// ```dart
/// final network = NetworkCollector();
/// final client = IncidentHttpClient(network, inner: http.Client());
/// IncidentSDK.init(..., collectors: [network.collector]);
/// ```
class IncidentHttpClient extends http.BaseClient {
  IncidentHttpClient(this._collector, {http.Client? inner})
      : _inner = inner ?? http.Client();

  final NetworkCollector _collector;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final stopwatch = Stopwatch()..start();
    final requestHeaders = Map<String, String>.from(request.headers);
    final requestContentType = request.headers['content-type'];

    // Only a concrete `http.Request` (what every `get`/`post`/... helper
    // builds) exposes its body without consuming a single-use stream —
    // a caller-built `http.StreamedRequest` is forwarded untouched and its
    // body is simply not captured.
    final requestBodyBytes =
        request is http.Request ? request.bodyBytes : null;
    final requestBytes = requestBodyBytes?.length ?? request.contentLength;

    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (e) {
      stopwatch.stop();
      _collector.record(
        method: request.method,
        url: request.url,
        requestHeaders: requestHeaders,
        requestBytes: requestBytes,
        requestBodyBytes: requestBodyBytes,
        requestContentType: requestContentType,
        duration: stopwatch.elapsed,
        error: e.toString(),
      );
      rethrow;
    }

    // The response body is bridged chunk-by-chunk instead of buffered with
    // `toBytes()` before being returned: fully buffering would make every
    // response wait for its entire download before the caller sees a single
    // byte, which is exactly the streaming/backpressure behaviour adopting
    // this client must not take away (constraint: swapping the client must
    // not otherwise change how the app talks to the network). At most
    // [kMaxInspectBytes] of the body is kept, in memory, for the shape
    // extraction and (opt-in) capture `NetworkCollector.record` does; the
    // rest streams straight through to the real caller and is only counted,
    // never held onto.
    final responseContentType = response.headers['content-type'];
    final prefix = BytesBuilder();
    var truncated = false;
    var totalBytes = 0;
    var finished = false;
    late StreamSubscription<List<int>> sub;

    // Headers (and therefore `response.statusCode`) already arrived
    // successfully by this point — a body-level error or cancellation is
    // not a failure to reach the server, so the status code it did answer
    // with is always worth keeping, not just on the success path.
    void finish({String? error}) {
      if (finished) return;
      finished = true;
      stopwatch.stop();
      _collector.record(
        method: request.method,
        url: request.url,
        requestHeaders: requestHeaders,
        requestBytes: requestBytes,
        requestBodyBytes: requestBodyBytes,
        requestContentType: requestContentType,
        statusCode: response.statusCode,
        responseHeaders: response.headers,
        responseBytes: totalBytes,
        // A truncated prefix is never handed to the collector: partial JSON
        // would either fail to parse (losing the shape entirely) or, worse,
        // parse into a shape that misdescribes data cut off mid-value.
        responseBodyBytes: truncated ? null : prefix.toBytes(),
        responseContentType: responseContentType,
        duration: stopwatch.elapsed,
        error: error,
      );
    }

    // The source stream is only subscribed to once `passthrough` itself
    // gets a listener (`onListen`, not eagerly here in `send`) — a plain
    // `http.Client` never reads a byte of the body until the caller asks
    // for one, and subscribing eagerly would buffer an unbounded amount of
    // data in `passthrough` for a caller that awaits something else first.
    late final StreamController<List<int>> passthrough;
    passthrough = StreamController<List<int>>(
      onListen: () {
        sub = response.stream.listen(
          (chunk) {
            totalBytes += chunk.length;
            if (!truncated) {
              final capacity = kMaxInspectBytes - prefix.length;
              if (chunk.length <= capacity) {
                prefix.add(chunk);
              } else {
                if (capacity > 0) prefix.add(chunk.sublist(0, capacity));
                truncated = true;
              }
            }
            passthrough.add(chunk);
          },
          onDone: () {
            finish();
            passthrough.close();
          },
          onError: (Object e, StackTrace st) {
            finish(error: e.toString());
            passthrough.addError(e, st);
            passthrough.close();
          },
          cancelOnError: true,
        );
      },
      onPause: () => sub.pause(),
      onResume: () => sub.resume(),
      onCancel: () {
        // The caller cancelling mid-body is not "no incident happened" —
        // it is a request that got a response and then had its body
        // abandoned, which is still worth an entry (marked truncated, since
        // whatever prefix was buffered may not be the whole story).
        truncated = true;
        finish(error: 'cancelled');
        return sub.cancel();
      },
    );

    return http.StreamedResponse(
      passthrough.stream,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

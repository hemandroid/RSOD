import 'dart:convert';
import 'dart:io';

/// Thrown by an [IncidentTransport] for a batch the backend will never
/// accept as-is (a malformed payload, a rejected token). [IncidentUploader]
/// discards it instead of retrying forever; anything else thrown is assumed
/// transient and retried with backoff.
class PermanentUploadFailure implements Exception {
  final String reason;
  const PermanentUploadFailure(this.reason);

  @override
  String toString() => 'PermanentUploadFailure: $reason';
}

/// Thrown for HTTP 413: the *request* was too big, not any one incident in
/// it, so [IncidentUploader] splits the batch and retries the halves rather
/// than discarding everything in it.
class PayloadTooLargeFailure implements Exception {
  const PayloadTooLargeFailure();

  @override
  String toString() => 'PayloadTooLargeFailure';
}

/// Thrown for HTTP 429. Carries the server's `Retry-After` value when it
/// sent one, so [IncidentUploader] can honour it instead of guessing.
class RateLimited implements Exception {
  final Duration? retryAfter;
  const RateLimited([this.retryAfter]);

  @override
  String toString() => 'RateLimited(retryAfter: $retryAfter)';
}

/// The one seam between the uploader and wherever incidents actually go.
/// Batching, retry classification and backoff are policy that stays the same
/// regardless of backend, so only "how a batch is sent" is pulled behind an
/// interface — which also lets the uploader's tests run against a fake, with
/// no socket ever opened.
abstract class IncidentTransport {
  /// Return normally only once the backend has confirmed receipt — that's
  /// what tells the uploader it's safe to delete the batch.
  ///
  /// Throw [PermanentUploadFailure] for a batch that will never succeed,
  /// [PayloadTooLargeFailure] for one that might succeed split up, or
  /// [RateLimited] when the backend says to slow down. Anything else is
  /// treated as an ordinary failure worth retrying later.
  Future<void> send(List<Map<String, dynamic>> incidents);
}

/// Default transport: `POST /ingest` with a bearer token, over [HttpClient]
/// so the package needs no HTTP dependency beyond `dart:io`.
class HttpIncidentTransport implements IncidentTransport {
  final Uri endpoint;
  final String appToken;
  final HttpClient _client;

  /// [client] is injectable so tests can drive every status branch below
  /// with a hand-written fake — this method is the one place that bug lived
  /// last time.
  HttpIncidentTransport({
    required this.endpoint,
    required this.appToken,
    HttpClient? client,
  }) : _client = client ?? HttpClient();

  @override
  Future<void> send(List<Map<String, dynamic>> incidents) async {
    final request = await _client.postUrl(endpoint);
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $appToken');
    request.write(jsonEncode(incidents));

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final status = response.statusCode;

    if (status >= 200 && status < 300) return;

    // Explicit per-status classification, not a blanket 4xx range: several
    // 4xx codes mean "try again", and lumping them in with the permanent
    // ones would discard good incidents right when the backend is struggling.

    if (status == 401) {
      // The app token is provisioned once at build time (see
      // IncidentSDK.init), not refreshed at runtime, so a 401 is a
      // configuration mistake that resending won't fix.
      throw PermanentUploadFailure('HTTP 401${_suffix(body)}');
    }

    if (status == 408) {
      throw HttpException('incident_sdk: upload timed out (HTTP 408)');
    }

    if (status == 429) {
      throw RateLimited(_retryAfter(response));
    }

    if (status == 413) {
      throw const PayloadTooLargeFailure();
    }

    if (status >= 400 && status < 500) {
      throw PermanentUploadFailure('HTTP $status${_suffix(body)}');
    }

    throw HttpException('incident_sdk: upload failed with HTTP $status');
  }

  String _suffix(String body) => body.isEmpty ? '' : ': $body';

  /// Parses `Retry-After` as either seconds or an HTTP-date; null for
  /// anything else, so the caller falls back to its own backoff.
  Duration? _retryAfter(HttpClientResponse response) {
    final header = response.headers.value(HttpHeaders.retryAfterHeader);
    if (header == null) return null;
    final seconds = int.tryParse(header);
    // Floored at zero: the uploader's cap only clamps from above.
    if (seconds != null) {
      return seconds <= 0 ? Duration.zero : Duration(seconds: seconds);
    }
    try {
      final delta = HttpDate.parse(header).difference(DateTime.now().toUtc());
      return delta.isNegative ? Duration.zero : delta;
    } catch (_) {
      return null;
    }
  }
}

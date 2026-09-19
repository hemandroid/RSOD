import 'dart:convert';
import 'dart:io';

/// Thrown by an [IncidentTransport] to report a batch the backend will never
/// accept as-is — a malformed payload, a rejected token. [IncidentUploader]
/// discards a batch that fails this way instead of retrying it forever.
/// Anything else the transport throws (a 5xx, a dropped connection, a
/// timeout) is assumed transient and retried with backoff.
class PermanentUploadFailure implements Exception {
  final String reason;
  const PermanentUploadFailure(this.reason);

  @override
  String toString() => 'PermanentUploadFailure: $reason';
}

/// Thrown for HTTP 413: the *request* was too big, not any one incident in
/// it. Discarding the whole batch the way [PermanentUploadFailure] does
/// would take down every well-formed incident riding alongside the oversized
/// one — [IncidentUploader] instead splits the batch and retries the halves,
/// and reserves discarding for an incident that is still too large entirely
/// on its own.
class PayloadTooLargeFailure implements Exception {
  const PayloadTooLargeFailure();

  @override
  String toString() => 'PayloadTooLargeFailure';
}

/// Thrown for HTTP 429: transient by definition — the backend is asking for
/// less traffic, not rejecting this payload. Carries the server's
/// `Retry-After` value when it sent one, so [IncidentUploader] can honour the
/// backend's own guidance instead of guessing with its own backoff.
class RateLimited implements Exception {
  final Duration? retryAfter;
  const RateLimited([this.retryAfter]);

  @override
  String toString() => 'RateLimited(retryAfter: $retryAfter)';
}

/// The one seam between the uploader and wherever incidents actually go.
///
/// Everything else in this package — batching, retry classification, backoff
/// — is policy that stays the same regardless of backend. Only "how a batch
/// is actually sent" changes when the backend does, so that is the only part
/// pulled behind an interface. It also earns its place for testing: the
/// uploader's tests exercise real batching and backoff logic against a fake
/// implementation, with no socket ever opened.
abstract class IncidentTransport {
  /// Uploads one batch of already-encoded incidents. Return normally only
  /// once the backend has confirmed receipt — that return is what tells the
  /// uploader it is safe to delete them.
  ///
  /// Throw [PermanentUploadFailure] for a batch that will never succeed,
  /// [PayloadTooLargeFailure] for one that might succeed split up, or
  /// [RateLimited] when the backend says to slow down. Throw anything else
  /// (a 5xx, a dropped socket, a timeout) for an ordinary failure worth
  /// retrying later.
  Future<void> send(List<Map<String, dynamic>> incidents);
}

/// Default transport: `POST /ingest` with a bearer token, over [HttpClient]
/// so the package needs no HTTP dependency beyond `dart:io`.
class HttpIncidentTransport implements IncidentTransport {
  /// Full ingest URL, e.g. `https://incidents.example.com/ingest`.
  final Uri endpoint;
  final String appToken;
  final HttpClient _client;

  /// [client] is injectable so tests can drive every status branch below
  /// with a hand-written fake — this method is the one place that bug lived
  /// last time, and it should never again be the one place nothing tests.
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

    // Explicit per-status classification rather than a blanket 4xx range:
    // several 4xx codes mean "try again", not "this is broken", and lumping
    // them in with the truly permanent ones would throw away good incidents
    // at exactly the moment the backend is struggling — the one outcome
    // this package exists to prevent.

    if (status == 401) {
      // Deliberate policy, not a side effect of a range check: the brief
      // calls a rejected token permanent, and there is no way to tell
      // "revoked" apart from "expired but renewable" from here. In practice
      // the app token is provisioned once at build time (see
      // IncidentSDK.init) rather than refreshed at runtime, so a 401 for it
      // is a configuration mistake that resending will not fix.
      throw PermanentUploadFailure('HTTP 401${_suffix(body)}');
    }

    if (status == 408) {
      // A request timeout is the backend (or the network) being slow, not a
      // verdict on the payload.
      throw HttpException('incident_sdk: upload timed out (HTTP 408)');
    }

    if (status == 429) {
      throw RateLimited(_retryAfter(response));
    }

    if (status == 413) {
      throw const PayloadTooLargeFailure();
    }

    if (status >= 400 && status < 500) {
      // Everything else in the 4xx range — malformed payload, not found,
      // unprocessable entity — is the backend telling us this exact request
      // is bad. Sending it again unchanged changes nothing.
      throw PermanentUploadFailure('HTTP $status${_suffix(body)}');
    }

    // 5xx, or any status we don't otherwise recognise: the backend may be
    // fine next time, so this is worth retrying.
    throw HttpException('incident_sdk: upload failed with HTTP $status');
  }

  String _suffix(String body) => body.isEmpty ? '' : ': $body';

  /// Parses `Retry-After`, which the spec allows as either a number of
  /// seconds or an HTTP-date. Returns null for anything else rather than
  /// guessing — the caller falls back to its own backoff in that case.
  Duration? _retryAfter(HttpClientResponse response) {
    final header = response.headers.value(HttpHeaders.retryAfterHeader);
    if (header == null) return null;
    final seconds = int.tryParse(header);
    // Floored at zero: the uploader's cap only clamps from above, so a
    // negative value would sail through and retry with no delay at all.
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

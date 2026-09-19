import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:incident_sdk/src/collectors/network_collector.dart';

List<Map<String, dynamic>> _requests(NetworkCollector c) =>
    (c.collector.collect()['requests'] as List).cast<Map<String, dynamic>>();

void main() {
  _round4Regressions();
  group('redaction', () {
    test('redacts every query value regardless of key name', () {
      final c = NetworkCollector();
      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/search?q=jane@example.com&page=2'),
        duration: const Duration(milliseconds: 5),
      );

      final url = _requests(c).single['url'] as String;
      expect(url, isNot(contains('jane@example.com')));
      expect(url, isNot(contains('page=2')));
      expect(Uri.parse(url).queryParameters, {'q': '[redacted]', 'page': '[redacted]'});
    });

    test('redacts known-sensitive headers with no opt-out', () {
      final c = NetworkCollector();
      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/me'),
        requestHeaders: const {
          'Authorization': 'Bearer super-secret-token',
          'Cookie': 'session=abc123',
          'X-Api-Key': 'key-123',
          'Accept': 'application/json',
        },
        duration: const Duration(milliseconds: 5),
      );

      final headers =
          _requests(c).single['requestHeaders'] as Map<String, dynamic>;
      expect(headers['Authorization'], '[redacted]');
      expect(headers['Cookie'], '[redacted]');
      expect(headers['X-Api-Key'], '[redacted]');
      expect(headers['Accept'], 'application/json',
          reason: 'only the known-sensitive names are redacted');

      final dumped = jsonEncode(_requests(c));
      expect(dumped, isNot(contains('super-secret-token')));
      expect(dumped, isNot(contains('abc123')));
      expect(dumped, isNot(contains('key-123')));
    });

    test('response headers are redacted the same way', () {
      final c = NetworkCollector();
      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/me'),
        statusCode: 200,
        responseHeaders: const {'Set-Cookie': 'session=xyz'},
        duration: const Duration(milliseconds: 5),
      );

      final headers =
          _requests(c).single['responseHeaders'] as Map<String, dynamic>;
      expect(headers['Set-Cookie'], '[redacted]');
    });

    test('redacts userinfo credentials embedded in the URL', () {
      final c = NetworkCollector();
      c.record(
        method: 'GET',
        url: Uri.parse('https://user:pass@api.example.com/x?q=1'),
        duration: const Duration(milliseconds: 5),
      );

      final url = _requests(c).single['url'] as String;
      expect(url, isNot(contains('user:pass')));
      expect(Uri.parse(url).userInfo, isNot(contains('pass')));
    });

    test('redacts email- and token-like path segments, keeps route shape',
        () {
      final c = NetworkCollector();
      c.record(
        method: 'GET',
        url: Uri.parse(
          'https://api.example.com/users/jane@example.com/orders/42',
        ),
        duration: const Duration(milliseconds: 5),
      );

      final url = _requests(c).single['url'] as String;
      expect(url, isNot(contains('jane@example.com')));
      final segments = Uri.parse(url).pathSegments;
      expect(segments, ['users', '[redacted]', 'orders', '42'],
          reason: 'route shape (users/.../orders/<id>) is still useful; '
              'only the email-shaped segment is redacted');
    });

    test('keeps ordinary hyphenated route words in the path', () {
      final c = NetworkCollector();
      c.record(
        method: 'GET',
        url: Uri.parse(
          'https://api.example.com/subscription-management/openid-configuration',
        ),
        duration: const Duration(milliseconds: 5),
      );

      final url = _requests(c).single['url'] as String;
      expect(Uri.parse(url).pathSegments,
          ['subscription-management', 'openid-configuration']);
    });

    test('redacts a hex-digest-shaped path segment', () {
      final c = NetworkCollector();
      c.record(
        method: 'GET',
        url: Uri.parse(
          'https://api.example.com/files/a3f5b2c1d4e6f708a9b0c1d2e3f40506',
        ),
        duration: const Duration(milliseconds: 5),
      );

      final url = _requests(c).single['url'] as String;
      expect(url, isNot(contains('a3f5b2c1d4e6f708a9b0c1d2e3f40506')));
    });

    test('redacts an OAuth bearer token carried in the URL fragment', () {
      final c = NetworkCollector();
      c.record(
        method: 'GET',
        url: Uri.parse(
          'https://app.example.com/callback#access_token=eyJhbGciOiJIUzI1NiJ9.abc&token_type=bearer',
        ),
        duration: const Duration(milliseconds: 5),
      );

      final url = _requests(c).single['url'] as String;
      expect(url, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
      final fragment = Uri.parse(url).fragment;
      // Policy changed in round 4: fragments are redacted wholesale rather
      // than parsed, because parsing leaked keys twice.
      expect(fragment, 'redacted');
      expect(fragment, isNot(contains('access_token')),
          reason: 'every fragment value is redacted, like a query value — '
              'the fragment is redacted wholesale, never parsed');
    });

    test(
        'redacts a bare (non key=value) fragment wholesale instead of '
        'echoing it as a key', () {
      final c = NetworkCollector();
      c.record(
        method: 'GET',
        url: Uri.parse('https://app.example.com/docs#section-2'),
        duration: const Duration(milliseconds: 5),
      );

      final url = _requests(c).single['url'] as String;
      expect(url, isNot(contains('section-2')),
          reason: 'Uri.splitQueryString("section-2") parses to '
              '{"section-2": ""}, which is non-empty — a naive '
              'isEmpty check on that result would let the fragment through '
              'verbatim as a key');
    });
  });

  group('response shape extraction', () {
    // Each of these stays below _kDictionaryMinKeys (4) on purpose: a flat
    // record with 4+ scalar-only fields is now deliberately swept into the
    // dictionary collapse (leaf-insensitive shape comparison — see the
    // "loses field names" tests further down), so type-mapping coverage is
    // split across a few small records instead of one big one.
    test('maps scalar JSON types to their Dart type name, never a value',
        () {
      final c = NetworkCollector();
      final body = utf8.encode(jsonEncode({
        'id': 42,
        'verified': true,
        'balance': 3.5,
      }));

      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/user'),
        statusCode: 200,
        responseBodyBytes: body,
        responseContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final shape =
          _requests(c).single['responseShape'] as Map<String, dynamic>;
      expect(shape, {'id': 'int', 'verified': 'bool', 'balance': 'double'});
    });

    test('maps null and string types, and never leaks the string value', () {
      final c = NetworkCollector();
      final body = utf8.encode(jsonEncode({
        'payment': null,
        'email': 'user@example.com',
      }));

      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/user'),
        statusCode: 200,
        responseBodyBytes: body,
        responseContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final shape =
          _requests(c).single['responseShape'] as Map<String, dynamic>;
      expect(shape, {'payment': 'Null', 'email': 'String'});

      final dumped = jsonEncode(_requests(c));
      expect(dumped, isNot(contains('user@example.com')));
    });

    test('maps a list to a single-element shape', () {
      final c = NetworkCollector();
      final body = utf8.encode(jsonEncode({
        'tags': ['a', 'b'],
      }));

      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/user'),
        statusCode: 200,
        responseBodyBytes: body,
        responseContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final shape =
          _requests(c).single['responseShape'] as Map<String, dynamic>;
      expect(shape, {
        'tags': ['String'],
      });
    });

    test(
        'a flat record of 4+ scalar-only fields collapses too — the '
        'accepted cost of comparing shapes leaf-insensitively', () {
      final c = NetworkCollector();
      final body = utf8.encode(jsonEncode({
        'street': '1 Main St',
        'city': 'Springfield',
        'state': 'IL',
        'zip': '62701',
      }));

      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/address'),
        statusCode: 200,
        responseBodyBytes: body,
        responseContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final entry = _requests(c).single;
      expect(jsonEncode(entry), isNot(contains('Springfield')));
      final shape = entry['responseShape'] as Map<String, dynamic>;
      // The emitted representative is the actual majority *shape* (here,
      // every value is a String), not the bare comparison wildcard — still
      // no value is ever included, but "a dictionary of 4 strings" is more
      // useful than "a dictionary of 4 somethings" for the same zero risk.
      expect(shape, {'<dynamic>': 'String', '_keyCount': 4});
    });

    test('nested objects are shaped recursively', () {
      final c = NetworkCollector();
      final body = utf8.encode(jsonEncode({
        'user': {'name': 'Jane', 'age': 30}
      }));

      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/user'),
        statusCode: 200,
        responseBodyBytes: body,
        responseContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final shape =
          _requests(c).single['responseShape'] as Map<String, dynamic>;
      expect(shape['user'], {'name': 'String', 'age': 'int'});
    });

    test('is captured even when body capture is disabled', () {
      final c = NetworkCollector(); // captureBody defaults to false
      final body = utf8.encode(jsonEncode({'ok': true}));

      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/health'),
        statusCode: 200,
        responseBodyBytes: body,
        responseContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final entry = _requests(c).single;
      expect(entry['responseShape'], {'ok': 'bool'});
      expect(entry.containsKey('responseBody'), isFalse);
    });

    test('non-JSON content types produce no shape', () {
      final c = NetworkCollector();
      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/image'),
        statusCode: 200,
        responseBodyBytes: utf8.encode('not json'),
        responseContentType: 'text/plain',
        duration: const Duration(milliseconds: 5),
      );

      expect(_requests(c).single.containsKey('responseShape'), isFalse);
    });

    test(
        'a two-key record of nested objects keeps its field names — below '
        'threshold regardless of the nested shapes', () {
      final c = NetworkCollector();
      final body = utf8.encode(jsonEncode({
        'billing': {'city': 'Springfield', 'zip': '62701'},
        'shipping': {'city': 'Shelbyville', 'zip': '62565'},
      }));

      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/order/1'),
        statusCode: 200,
        responseBodyBytes: body,
        responseContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final shape =
          _requests(c).single['responseShape'] as Map<String, dynamic>;
      expect(shape, {
        'billing': {'city': 'String', 'zip': 'String'},
        'shipping': {'city': 'String', 'zip': 'String'},
      });
    });

    test(
        'a small two-key record keeps its field names even though a lone '
        'email key exists elsewhere in it', () {
      // Below the dictionary threshold, a PII-shaped key is still caught by
      // the lexical fallback rather than being emitted or triggering a
      // needless collapse of the whole (mostly real) record.
      final c = NetworkCollector();
      final body = utf8.encode(jsonEncode({
        'alice@example.com': {'active': true},
        'bob@example.com': {'active': false},
      }));

      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/users'),
        statusCode: 200,
        responseBodyBytes: body,
        responseContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final entry = _requests(c).single;
      final dumped = jsonEncode(entry);
      expect(dumped, isNot(contains('alice@example.com')));
      expect(dumped, isNot(contains('bob@example.com')));

      final shape = entry['responseShape'] as Map<String, dynamic>;
      expect(shape.keys, everyElement(startsWith('<redacted-key')));
      expect(shape.values, [
        {'active': 'bool'},
        {'active': 'bool'},
      ]);
    });

    test(
        'collapses a larger dictionary keyed by emails, emitting no key at '
        'all', () {
      final c = NetworkCollector();
      final body = utf8.encode(jsonEncode({
        for (var i = 0; i < 5; i++) 'user$i@example.com': {'active': i.isEven},
      }));

      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/users'),
        statusCode: 200,
        responseBodyBytes: body,
        responseContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final entry = _requests(c).single;
      expect(jsonEncode(entry), isNot(contains('@example.com')));

      final shape = entry['responseShape'] as Map<String, dynamic>;
      expect(shape['_keyCount'], 5);
      expect(shape['<dynamic>'], {'active': 'bool'});
    });

    test(
        'collapses a dictionary keyed by plain usernames — the case no key '
        'pattern alone can catch, because a username and a field name are '
        'lexically identical', () {
      final c = NetworkCollector();
      final body = utf8.encode(jsonEncode({
        'jsmith': {'active': true},
        'alice_w': {'active': false},
        'Sarah': {'active': true},
        'hemasai2010': {'active': false},
      }));

      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/users'),
        statusCode: 200,
        responseBodyBytes: body,
        responseContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final entry = _requests(c).single;
      final dumped = jsonEncode(entry);
      for (final username in ['jsmith', 'alice_w', 'Sarah', 'hemasai2010']) {
        expect(dumped, isNot(contains(username)));
      }

      final shape = entry['responseShape'] as Map<String, dynamic>;
      expect(shape['_keyCount'], 4);
      expect(shape['<dynamic>'], {'active': 'bool'});
    });

    test(
        'a small record with homogeneous-typed fields keeps its key names '
        '(too few entries to read as a dictionary)', () {
      final c = NetworkCollector();
      final body = utf8.encode(jsonEncode({'width': 10, 'height': 20}));

      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/size'),
        statusCode: 200,
        responseBodyBytes: body,
        responseContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final shape =
          _requests(c).single['responseShape'] as Map<String, dynamic>;
      expect(shape, {'width': 'int', 'height': 'int'});
    });

    test(
        'a heterogeneous two-field record keeps its field names — this is '
        'the diagnostic the field exists for', () {
      final c = NetworkCollector();
      final body =
          utf8.encode(jsonEncode({'payment': null, 'status': 'expired'}));

      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/order/1'),
        statusCode: 200,
        responseBodyBytes: body,
        responseContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final shape =
          _requests(c).single['responseShape'] as Map<String, dynamic>;
      expect(shape, {'payment': 'Null', 'status': 'String'});
    });

    test(
        'redacts both keys of a hex-digest-keyed map, not just the '
        'digit-leading one', () {
      final c = NetworkCollector();
      final digestA = 'a3f5b2c1d4e6f708a9b0c1d2e3f40506';
      final digestB = '3f5b2c1d4e6f708a9b0c1d2e3f405060a';
      final body = utf8.encode(jsonEncode({
        digestA: {'hits': 1},
        digestB: {'hits': 2},
      }));

      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/cache'),
        statusCode: 200,
        responseBodyBytes: body,
        responseContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final dumped = jsonEncode(_requests(c));
      expect(dumped, isNot(contains(digestA)));
      expect(dumped, isNot(contains(digestB)));
    });

    test(
        'redacts only the unsafe key when a schema-shaped object has one '
        'dynamic-looking key', () {
      final c = NetworkCollector();
      final body = utf8.encode(jsonEncode({
        'status': 'ok',
        'user@example.com': true,
      }));

      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/mixed'),
        statusCode: 200,
        responseBodyBytes: body,
        responseContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final shape = _requests(c).single['responseShape'] as Map<String, dynamic>;
      expect(shape['status'], 'String');
      expect(shape.keys.any((k) => k.toString().startsWith('<redacted-key')),
          isTrue);
      expect(jsonEncode(shape), isNot(contains('user@example.com')));
    });

    test(
        'caps recursion depth on deeply nested JSON instead of overflowing '
        'the stack', () {
      final c = NetworkCollector();
      const depth = 5000;
      final body =
          utf8.encode('${'{"a":' * depth}null${'}' * depth}');

      expect(
        () => c.record(
          method: 'GET',
          url: Uri.parse('https://api.example.com/deep'),
          statusCode: 200,
          responseBodyBytes: body,
          responseContentType: 'application/json',
          duration: const Duration(milliseconds: 5),
        ),
        returnsNormally,
      );

      final shape = _requests(c).single['responseShape'];
      expect(jsonEncode(shape), contains('MaxDepthExceeded'));
    });
  });

  group('body capture opt-in', () {
    test('bodies are absent by default', () {
      final c = NetworkCollector();
      c.record(
        method: 'POST',
        url: Uri.parse('https://api.example.com/login'),
        requestBodyBytes: utf8.encode(jsonEncode({'password': 'hunter2'})),
        requestContentType: 'application/json',
        statusCode: 200,
        responseBodyBytes: utf8.encode(jsonEncode({'ok': true})),
        responseContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final entry = _requests(c).single;
      expect(entry.containsKey('requestBody'), isFalse);
      expect(entry.containsKey('responseBody'), isFalse);
    });

    test('captured bodies redact known-sensitive JSON keys', () {
      final c = NetworkCollector(captureBody: true);
      c.record(
        method: 'POST',
        url: Uri.parse('https://api.example.com/login'),
        requestBodyBytes:
            utf8.encode(jsonEncode({'username': 'jane', 'password': 'hunter2'})),
        requestContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final captured = _requests(c).single['requestBody'] as String;
      expect(captured, contains('jane'));
      expect(captured, isNot(contains('hunter2')));
    });

    test(
        'captured bodies redact dynamic-looking keys, not just known '
        'sensitive value keys', () {
      final c = NetworkCollector(captureBody: true);
      c.record(
        method: 'POST',
        url: Uri.parse('https://api.example.com/import'),
        requestBodyBytes: utf8.encode(jsonEncode({
          'alice@example.com': {'role': 'admin'},
        })),
        requestContentType: 'application/json',
        duration: const Duration(milliseconds: 5),
      );

      final captured = _requests(c).single['requestBody'] as String;
      expect(captured, isNot(contains('alice@example.com')));
    });

    test('captured bodies are truncated to maxBodyBytes', () {
      final c = NetworkCollector(captureBody: true, maxBodyBytes: 10);
      c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/text'),
        responseBodyBytes: utf8.encode('a' * 100),
        responseContentType: 'text/plain',
        duration: const Duration(milliseconds: 5),
      );

      final captured = _requests(c).single['responseBody'] as String;
      expect(captured.length, 10);
    });
  });

  group('ring buffer', () {
    test('drops the oldest entry once maxEntries is reached', () {
      final c = NetworkCollector(maxEntries: 2);
      for (final path in ['/a', '/b', '/c']) {
        c.record(
          method: 'GET',
          url: Uri.parse('https://api.example.com$path'),
          duration: const Duration(milliseconds: 1),
        );
      }

      final urls = _requests(c).map((e) => e['url']).toList();
      expect(urls, ['https://api.example.com/b', 'https://api.example.com/c']);
    });

    test('never exceeds the cap under a flood of requests', () {
      final c = NetworkCollector(maxEntries: 5);
      for (var i = 0; i < 500; i++) {
        c.record(
          method: 'GET',
          url: Uri.parse('https://api.example.com/$i'),
          duration: const Duration(milliseconds: 1),
        );
      }

      expect(_requests(c).length, 5);
    });
  });

  test('records method, status, duration and sizes', () {
    final c = NetworkCollector();
    c.record(
      method: 'PUT',
      url: Uri.parse('https://api.example.com/thing/1'),
      requestBytes: 42,
      statusCode: 204,
      responseBytes: 0,
      duration: const Duration(milliseconds: 123),
    );

    final entry = _requests(c).single;
    expect(entry['method'], 'PUT');
    expect(entry['statusCode'], 204);
    expect(entry['requestBytes'], 42);
    expect(entry['responseBytes'], 0);
    expect(entry['durationMs'], 123);
  });

  test('records a network error without a status code', () {
    final c = NetworkCollector();
    c.record(
      method: 'GET',
      url: Uri.parse('https://api.example.com/down'),
      duration: const Duration(milliseconds: 30),
      error: 'SocketException: Connection refused',
    );

    final entry = _requests(c).single;
    expect(entry.containsKey('statusCode'), isFalse);
    expect(entry['error'], contains('Connection refused'));
  });
}

// Round 4 regressions: the reviewer defeated the previous shape-equality rule
// with optional fields and exact ties, and got an email through the fragment
// guard.
void _round4Regressions() {
  void recordJson(NetworkCollector c, String body) => c.record(
        method: 'GET',
        url: Uri.parse('https://api.example.com/x'),
        statusCode: 200,
        duration: Duration.zero,
        responseBodyBytes: utf8.encode(body),
        responseContentType: 'application/json',
      );

  group('round 4 - kind homogeneity', () {
    test('optional fields no longer veto the collapse', () {
      final c = NetworkCollector();
      recordJson(
        c,
        '{"jsmith":{"theme":"dark"},'
        '"alice_w":{"theme":"dark","beta":true},'
        '"sarah":{"theme":"light","lang":"en"},'
        '"bob99":{"theme":"dark","tz":"UTC"},'
        '"carol":{"theme":"light"}}',
      );

      final dump = _requests(c).single.toString();
      for (final name in ['jsmith', 'alice_w', 'sarah', 'bob99', 'carol']) {
        expect(dump, isNot(contains(name)), reason: '$name leaked');
      }
      expect(dump, contains('_keyCount'));
    });

    test('an exact kind tie no longer leaks keys', () {
      final c = NetworkCollector();
      recordJson(
        c,
        '{"jsmith":{"active":true},"alice_w":{"active":false},'
        '"sarah":null,"bob99":null}',
      );

      final dump = _requests(c).single.toString();
      expect(dump, isNot(contains('jsmith')));
      expect(dump, isNot(contains('sarah')));
    });

    test('a partial-failure response still collapses', () {
      // 3 maps + 1 scalar. Requiring unanimous kinds here shipped every key.
      final c = NetworkCollector();
      recordJson(
        c,
        '{"jsmith":{"ok":true},"alice_w":{"ok":true},'
        '"sarah":{"ok":true},"bob99":"not found"}',
      );

      final dump = _requests(c).single.toString();
      for (final name in ['jsmith', 'alice_w', 'sarah', 'bob99']) {
        expect(dump, isNot(contains(name)), reason: '$name leaked');
      }
    });

    test('three maps and one list still collapses', () {
      final c = NetworkCollector();
      recordJson(
        c,
        '{"jsmith":{"ok":true},"alice_w":{"ok":true},'
        '"sarah":{"ok":true},"bob99":["admin"]}',
      );

      expect(_requests(c).single.toString(), isNot(contains('jsmith')));
    });

    test('a dictionary of maps is not reported as nulls', () {
      final c = NetworkCollector();
      recordJson(
        c,
        '{"jsmith":null,"alice_w":null,"sarah":null,"bob99":{"ok":true}}',
      );

      final dump = _requests(c).single.toString();
      expect(dump, isNot(contains('bob99')));
      expect(dump, contains('ok'), reason: 'representative should be the map');
    });

    test('record field names survive', () {
      final c = NetworkCollector();
      recordJson(c, '{"payment":null,"status":"expired"}');

      final dump = _requests(c).single.toString();
      expect(dump, contains('payment'));
      expect(dump, contains('status'));
    });

    test('billing/shipping keep their names', () {
      final c = NetworkCollector();
      recordJson(c, '{"billing":{"city":"x"},"shipping":{"city":"y"}}');

      final dump = _requests(c).single.toString();
      expect(dump, contains('billing'));
      expect(dump, contains('shipping'));
    });
  });

  group('round 4 - fragments', () {
    test('are redacted wholesale', () {
      final c = NetworkCollector();
      for (final fragment in [
        '/users/jane@example.com?tab=1',
        '/profile/550e8400-e29b-41d4-a716-446655440000?edit=1',
        'c2VjcmV0dG9rZW4=',
        'access_token=eyJhbGciOiJIUzI1NiJ9',
        'section-2',
      ]) {
        c.record(
          method: 'GET',
          url: Uri.parse('https://app.example.com/callback#$fragment'),
          statusCode: 200,
          duration: Duration.zero,
        );
      }

      final dump = _requests(c).toString();
      expect(dump, isNot(contains('jane@example.com')));
      expect(dump, isNot(contains('550e8400')));
      expect(dump, isNot(contains('c2VjcmV0dG9rZW4')));
      expect(dump, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
      expect(dump, contains('redacted'));
    });
  });

  group('round 5 - shape repetition', () {
    test('an even split across two kinds still collapses', () {
      // 2 maps + 2 lists. No kind holds a majority, so the kind rule alone
      // read this as a record and shipped all four usernames.
      final c = NetworkCollector();
      recordJson(
        c,
        '{"jsmith":{"role":"admin"},"alice_w":{"role":"user"},'
        '"sarah":["read","write"],"bob99":["read"]}',
      );

      final dump = _requests(c).single.toString();
      for (final name in ['jsmith', 'alice_w', 'sarah', 'bob99']) {
        expect(dump, isNot(contains(name)), reason: '$name leaked');
      }
    });

    test('field order does not make two entries look unrelated', () {
      final c = NetworkCollector();
      recordJson(
        c,
        '{"jsmith":{"role":"admin","tz":"UTC"},'
        '"alice_w":{"tz":"IST","role":"user"},'
        '"sarah":42,"bob99":"absent"}',
      );

      final dump = _requests(c).single.toString();
      for (final name in ['jsmith', 'alice_w', 'sarah', 'bob99']) {
        expect(dump, isNot(contains(name)), reason: '$name leaked');
      }
    });

    test('a record whose fields each have their own shape keeps its names', () {
      final c = NetworkCollector();
      recordJson(
        c,
        '{"id":1,"name":"jacket","address":{"city":"x"},"tags":["sale"]}',
      );

      final dump = _requests(c).single.toString();
      for (final field in ['id', 'name', 'address', 'tags']) {
        expect(dump, contains(field), reason: '$field was collapsed away');
      }
    });
  });
}

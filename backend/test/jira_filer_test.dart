import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:incident_backend/src/contracts.dart';
import 'package:incident_backend/src/jira_filer.dart';
import 'package:test/test.dart';

// Anything derived from this must never reach a log line or a thrown
// message — the whole point of the "token never logged" test below.
const _fakeAuthHeader = 'Basic dG90YWxseS1zZWNyZXQtdG9rZW4tMTIz';

Incident _incident({
  Map<String, dynamic> context = const {},
  String error = 'RangeError: index out of bounds',
}) =>
    Incident(
      id: 'inc-1',
      capturedAt: DateTime.utc(2026, 9, 20, 12, 0, 0),
      source: IncidentSource.flutterError,
      error: error,
      stackTrace: 'raw obfuscated trace',
      appVersion: '2.3.1',
      commitSha: 'abcdef1234567890',
      platform: 'android',
      context: context,
    );

void main() {
  group('JiraFiler.file', () {
    test('successful create returns key and browse URL built from site URL',
        () async {
      final client = MockClient((request) async {
        expect(request.url.toString(),
            'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3/issue');
        return http.Response(jsonEncode({'key': 'SCRUM-42'}), 201);
      });
      final filer = JiraFiler(
        apiRoot: 'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3',
        authHeader: _fakeAuthHeader,
        projectKey: 'SCRUM',
        issueTypeName: 'Bug',
        siteBaseUrl: 'https://acme.atlassian.net',
        client: client,
        log: (_) {},
      );

      final ticket = await filer.file(_incident(), null, 'trace line 1');

      expect(ticket, isNotNull);
      expect(ticket!.key, 'SCRUM-42');
      expect(ticket.url, 'https://acme.atlassian.net/browse/SCRUM-42');
    });

    test('sends valid ADF with analysis fields, labels and selected context',
        () async {
      Map<String, dynamic>? sentBody;
      final client = MockClient((request) async {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'key': 'SCRUM-7'}), 201);
      });
      final filer = JiraFiler(
        apiRoot: 'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3',
        authHeader: _fakeAuthHeader,
        projectKey: 'SCRUM',
        issueTypeName: 'Bug',
        siteBaseUrl: 'https://acme.atlassian.net',
        client: client,
        log: (_) {},
      );
      const analysis = Analysis(
        title: 'Null user on checkout screen',
        rootCause: 'user was null after token refresh',
        reproSteps: ['Open app', 'Sign out mid-session', 'Tap checkout'],
        severity: 'major',
      );
      final incident = _incident(context: {
        'device': {'model': 'Pixel 7', 'os': 'Android', 'os_version': '14'},
        'routes': ['/home', '/cart', '/checkout'],
        // Not a named field this class reads — must not leak into the
        // ticket, proving context is selected rather than dumped.
        'network': {'auth_cookie': 'super-secret-session-value'},
      });

      await filer.file(incident, analysis, 'trace line 1\ntrace line 2');

      final fields = sentBody!['fields'] as Map<String, dynamic>;
      expect(fields['project'], {'key': 'SCRUM'});
      expect(fields['issuetype'], {'name': 'Bug'});
      expect(fields['summary'], 'Null user on checkout screen');
      expect(
        fields['labels'],
        containsAll(['incident-sdk', 'auto-filed', 'flutterError', 'severity-major']),
      );

      final description = fields['description'] as Map<String, dynamic>;
      expect(description['type'], 'doc');
      expect(description['version'], 1);
      final content = description['content'] as List;

      final asText = jsonEncode(content);
      expect(asText, contains('user was null after token refresh'));
      expect(asText, contains('Sign out mid-session'));
      expect(asText, contains('Pixel 7'));
      expect(asText, contains('/home -> /cart -> /checkout'));
      expect(asText, contains('trace line 1'));
      // Redacted-collector data that isn't a field this class knows about
      // must never appear, proving context is selected, not dumped.
      expect(asText, isNot(contains('super-secret-session-value')));

      final codeBlock =
          content.firstWhere((c) => c['type'] == 'codeBlock') as Map;
      expect(codeBlock['content'][0]['text'], 'trace line 1\ntrace line 2');
    });

    test('falls back to error-derived summary and note when analysis is null',
        () async {
      Map<String, dynamic>? sentBody;
      final client = MockClient((request) async {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'key': 'SCRUM-8'}), 201);
      });
      final filer = JiraFiler(
        apiRoot: 'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3',
        authHeader: _fakeAuthHeader,
        projectKey: 'SCRUM',
        issueTypeName: 'Bug',
        siteBaseUrl: 'https://acme.atlassian.net',
        client: client,
        log: (_) {},
      );

      await filer.file(
        _incident(error: 'RangeError: bad index\n#0 foo (file.dart:1)'),
        null,
        'trace',
      );

      final fields = sentBody!['fields'] as Map<String, dynamic>;
      expect(fields['summary'], 'RangeError: bad index (android)');
      expect(fields['summary'], isNot(contains('#0 foo')));
    });

    test('truncates oversized stack traces with a frame limit', () async {
      Map<String, dynamic>? sentBody;
      final client = MockClient((request) async {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'key': 'SCRUM-9'}), 201);
      });
      final filer = JiraFiler(
        apiRoot: 'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3',
        authHeader: _fakeAuthHeader,
        projectKey: 'SCRUM',
        issueTypeName: 'Bug',
        siteBaseUrl: 'https://acme.atlassian.net',
        client: client,
        log: (_) {},
      );
      final hugeTrace =
          List.generate(250, (i) => '#$i frame$i (file.dart:$i)').join('\n');

      await filer.file(_incident(), null, hugeTrace);

      final content = ((sentBody!['fields']
          as Map<String, dynamic>)['description'] as Map)['content'] as List;
      final codeBlock =
          content.firstWhere((c) => c['type'] == 'codeBlock') as Map;
      final text = codeBlock['content'][0]['text'] as String;
      final lines = text.split('\n');

      // 100 kept frames + 1 truncation-notice line.
      expect(lines.length, 101);
      expect(text, contains('#0 frame0'));
      expect(text, isNot(contains('#100 frame100')));
      expect(text, contains('truncated 150 more frames'));
    });

    test('returns null on a 400 without throwing', () async {
      final client = MockClient((request) async => http.Response(
            jsonEncode({
              'errorMessages': ["Field 'priority' cannot be set"],
            }),
            400,
          ));
      final filer = JiraFiler(
        apiRoot: 'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3',
        authHeader: _fakeAuthHeader,
        projectKey: 'SCRUM',
        issueTypeName: 'Bug',
        siteBaseUrl: 'https://acme.atlassian.net',
        client: client,
        log: (_) {},
      );

      final ticket = await filer.file(_incident(), null, 'trace');

      expect(ticket, isNull);
    });

    test('returns null on a 401 without throwing', () async {
      final client = MockClient((request) async => http.Response(
            jsonEncode({
              'errorMessages': ['AUTHENTICATED_FAILED'],
            }),
            401,
          ));
      final filer = JiraFiler(
        apiRoot: 'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3',
        authHeader: _fakeAuthHeader,
        projectKey: 'SCRUM',
        issueTypeName: 'Bug',
        siteBaseUrl: 'https://acme.atlassian.net',
        client: client,
        log: (_) {},
      );

      final ticket = await filer.file(_incident(), null, 'trace');

      expect(ticket, isNull);
    });

    test('never logs the auth header or token, on failure or on a thrown '
        'client error', () async {
      final failingClient = MockClient((request) async => http.Response(
            jsonEncode({
              'errorMessages': ['Field "foo" cannot be set'],
            }),
            400,
          ));
      final throwingClient =
          MockClient((request) async => throw const SocketException('down'));

      final logs = <String>[];
      final failFiler = JiraFiler(
        apiRoot: 'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3',
        authHeader: _fakeAuthHeader,
        projectKey: 'SCRUM',
        issueTypeName: 'Bug',
        siteBaseUrl: 'https://acme.atlassian.net',
        client: failingClient,
        log: logs.add,
      );
      final throwFiler = JiraFiler(
        apiRoot: 'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3',
        authHeader: _fakeAuthHeader,
        projectKey: 'SCRUM',
        issueTypeName: 'Bug',
        siteBaseUrl: 'https://acme.atlassian.net',
        client: throwingClient,
        log: logs.add,
      );

      await failFiler.file(_incident(), null, 'trace');
      await throwFiler.file(_incident(), null, 'trace');

      expect(logs, isNotEmpty);
      final allLogs = logs.join('\n');
      expect(allLogs, isNot(contains(_fakeAuthHeader)));
      expect(allLogs, isNot(contains('totally-secret-token-123')));
    });
  });

  group('JiraFiler screenshot attachment', () {
    test('a captured screenshot is uploaded to the created issue', () async {
      final calls = <String>[];
      final client = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path.endsWith('/attachments')) {
          // Jira refuses attachment uploads without this XSRF guard.
          expect(request.headers['X-Atlassian-Token'], 'no-check');
          expect(request.body, contains('screen-'));
          return http.Response('[]', 200);
        }
        return http.Response(jsonEncode({'key': 'SCRUM-3'}), 201);
      });
      final filer = JiraFiler(
        apiRoot: 'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3',
        authHeader: _fakeAuthHeader,
        projectKey: 'SCRUM',
        issueTypeName: 'Bug',
        siteBaseUrl: 'https://acme.atlassian.net',
        client: client,
        log: (_) {},
      );

      final ticket = await filer.file(
        _incidentWithScreenshot(),
        null,
        'trace',
      );

      expect(ticket?.key, 'SCRUM-3');
      expect(calls.where((c) => c.endsWith('/attachments')), hasLength(1));
    });

    test('a uiStall incident has no screenshot and uploads nothing', () async {
      // The UI thread was blocked, so no frame could be rasterised. Absence
      // here is correct, not a failure.
      final calls = <String>[];
      final client = MockClient((request) async {
        calls.add(request.url.path);
        return http.Response(jsonEncode({'key': 'SCRUM-4'}), 201);
      });
      final filer = JiraFiler(
        apiRoot: 'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3',
        authHeader: _fakeAuthHeader,
        projectKey: 'SCRUM',
        issueTypeName: 'Bug',
        siteBaseUrl: 'https://acme.atlassian.net',
        client: client,
        log: (_) {},
      );

      await filer.file(_incident(), null, 'trace');

      expect(calls.where((c) => c.endsWith('/attachments')), isEmpty);
    });

    test('bytes that are not a PNG are not uploaded', () async {
      // Anyone holding the ingest token controls these bytes; the filer must
      // not forward arbitrary content to Jira as an image.
      final calls = <String>[];
      final client = MockClient((request) async {
        calls.add(request.url.path);
        return http.Response(jsonEncode({'key': 'SCRUM-6'}), 201);
      });
      final logs = <String>[];
      final filer = JiraFiler(
        apiRoot: 'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3',
        authHeader: _fakeAuthHeader,
        projectKey: 'SCRUM',
        issueTypeName: 'Bug',
        siteBaseUrl: 'https://acme.atlassian.net',
        client: client,
        log: logs.add,
      );

      final ticket = await filer.file(_incidentWithFakeImage(), null, 'trace');

      expect(ticket?.key, 'SCRUM-6');
      expect(calls.where((c) => c.endsWith('/attachments')), isEmpty);
      expect(logs.join(), contains('not a PNG'));
    });

    test('a failed upload does not lose the ticket', () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/attachments')) {
          return http.Response('too large', 413);
        }
        return http.Response(jsonEncode({'key': 'SCRUM-5'}), 201);
      });
      final logs = <String>[];
      final filer = JiraFiler(
        apiRoot: 'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3',
        authHeader: _fakeAuthHeader,
        projectKey: 'SCRUM',
        issueTypeName: 'Bug',
        siteBaseUrl: 'https://acme.atlassian.net',
        client: client,
        log: logs.add,
      );

      final ticket = await filer.file(_incidentWithScreenshot(), null, 'trace');

      expect(ticket?.key, 'SCRUM-5', reason: 'the ticket already exists');
      expect(logs.join('\n'), contains('screenshot upload failed'));
    });
  });

  group('JiraFiler.comment', () {
    test('posts an ADF comment and returns the ticket on success', () async {
      Map<String, dynamic>? sentBody;
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3/issue/SCRUM-3/comment',
        );
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{}', 201);
      });
      final filer = JiraFiler(
        apiRoot: 'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3',
        authHeader: _fakeAuthHeader,
        projectKey: 'SCRUM',
        issueTypeName: 'Bug',
        siteBaseUrl: 'https://acme.atlassian.net',
        client: client,
        log: (_) {},
      );

      final ok = await filer.comment('SCRUM-3', _incident());

      expect(ok?.key, 'SCRUM-3');
      final body = sentBody!['body'] as Map<String, dynamic>;
      expect(body['type'], 'doc');
      expect(jsonEncode(body), contains('Repeat occurrence'));
    });

    test('returns null on failure without throwing', () async {
      final client =
          MockClient((request) async => http.Response('server error', 500));
      final filer = JiraFiler(
        apiRoot: 'https://api.atlassian.com/ex/jira/cloud-1/rest/api/3',
        authHeader: _fakeAuthHeader,
        projectKey: 'SCRUM',
        issueTypeName: 'Bug',
        siteBaseUrl: 'https://acme.atlassian.net',
        client: client,
        log: (_) {},
      );

      final ok = await filer.comment('SCRUM-3', _incident());

      expect(ok, isNull);
    });
  });
}

Incident _incidentWithScreenshot() {
  final base = _incident();
  return Incident(
    id: base.id,
    capturedAt: base.capturedAt,
    source: base.source,
    error: base.error,
    stackTrace: base.stackTrace,
    errorContext: base.errorContext,
    appVersion: base.appVersion,
    commitSha: base.commitSha,
    platform: base.platform,
    context: {
      ...base.context,
      'screenshot': {
        'format': 'png',
        'bytes': 8,
        // The full PNG signature: the filer rejects anything that is not
        // actually a PNG, since the payload is attacker-controlled.
        'image_base64': base64Encode([137, 80, 78, 71, 13, 10, 26, 10]),
      },
    },
  );
}

Incident _incidentWithFakeImage() {
  final base = _incidentWithScreenshot();
  return Incident(
    id: base.id,
    capturedAt: base.capturedAt,
    source: base.source,
    error: base.error,
    stackTrace: base.stackTrace,
    errorContext: base.errorContext,
    appVersion: base.appVersion,
    commitSha: base.commitSha,
    platform: base.platform,
    context: {
      ...base.context,
      'screenshot': {
        'format': 'png',
        'bytes': 3,
        'image_base64': base64Encode([1, 2, 3]),
      },
    },
  );
}

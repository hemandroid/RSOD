import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:incident_backend/src/contracts.dart';
import 'package:incident_backend/src/groq_analyzer.dart';
import 'package:test/test.dart';

Incident _incident({Map<String, dynamic> context = const {}}) => Incident(
      id: 'inc-1',
      capturedAt: DateTime.utc(2026, 1, 1),
      source: IncidentSource.flutterError,
      error: 'RangeError: index out of range',
      stackTrace: 'unsymbolicated',
      appVersion: '1.2.3',
      commitSha: 'abc123',
      platform: 'android',
      errorContext: 'building CartScreen',
      context: context,
    );

GroqAnalyzer _analyzer(
  http.Client client, {
  Duration timeout = const Duration(seconds: 5),
  String? apiVersion,
}) =>
    GroqAnalyzer(
      endpoint: 'https://api.groq.com/openai/v1/chat/completions',
      authHeaderName: 'Authorization',
      authHeaderValue: 'Bearer test-secret-key',
      model: 'qwen/qwen3.8-27b',
      apiVersion: apiVersion,
      timeout: timeout,
      client: client,
      log: (_) {},
    );

http.Response _chatResponse(String content, {int statusCode = 200}) => http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {'content': content},
          },
        ],
      }),
      statusCode,
    );

const _validJson = '''
{
  "title": "Cart crashes on checkout with empty cart",
  "root_cause": "CartScreen reads items[0] before checking the list is non-empty.",
  "repro_steps": ["Open the app", "Remove all cart items", "Tap checkout"],
  "severity": "major",
  "suggested_fix": "Guard the checkout button on items.isEmpty."
}
''';

void main() {
  group('GroqAnalyzer.analyse', () {
    test('parses a clean JSON response', () async {
      final client = MockClient((request) async => _chatResponse(_validJson));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      expect(result!.title, 'Cart crashes on checkout with empty cart');
      expect(result.rootCause, contains('items[0]'));
      expect(result.reproSteps, [
        'Open the app',
        'Remove all cart items',
        'Tap checkout',
      ]);
      expect(result.severity, 'major');
      expect(result.suggestedFix, contains('items.isEmpty'));
    });

    test('parses JSON wrapped in ```json fences', () async {
      final client = MockClient((request) async => _chatResponse('```json\n$_validJson\n```'));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      expect(result!.title, 'Cart crashes on checkout with empty cart');
    });

    test('parses JSON preceded by leading prose', () async {
      final client = MockClient(
        (request) async => _chatResponse('Sure, here is the analysis:\n\n$_validJson'),
      );
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      expect(result!.severity, 'major');
    });

    test('a brace inside a string value does not break extraction', () async {
      const withBraceInString = '''
      Here you go:
      {
        "title": "Crash in reducer",
        "root_cause": "The reducer does `state = { ...state, x: 1 }` on a frozen object.",
        "repro_steps": ["Open settings", "Toggle dark mode"],
        "severity": "minor",
        "suggested_fix": "Clone before mutating."
      }
      ''';
      final client = MockClient((request) async => _chatResponse(withBraceInString));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      expect(result!.title, 'Crash in reducer');
    });

    test('malformed JSON returns null', () async {
      final client = MockClient((request) async => _chatResponse('{"title": "oops",'));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNull);
    });

    test('a missing required field returns null', () async {
      const missingRootCause = '''
      {
        "title": "Something broke",
        "repro_steps": ["Open the app"],
        "severity": "minor"
      }
      ''';
      final client = MockClient((request) async => _chatResponse(missingRootCause));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNull);
    });

    test('empty repro_steps keeps the analysis, minus the steps', () async {
      // Discarding a whole analysis over one absent field left half the
      // tickets in a six-failure run with no root cause at all.
      const emptySteps = '''
      {
        "title": "Something broke",
        "root_cause": "Unknown",
        "repro_steps": []
      }
      ''';
      final client = MockClient((request) async => _chatResponse(emptySteps));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      expect(result!.rootCause, 'Unknown');
      expect(result.reproSteps, isEmpty);
    });

    test('a missing title is synthesised from the incident', () async {
      const noTitle = '{"root_cause": "products.first on an empty list"}';
      final client = MockClient((request) async => _chatResponse(noTitle));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      // `isNotEmpty` passed while the fallback was a literal '${...}' string
      // with escaped dollars — assert the real values reach the title.
      expect(result!.title, contains('RangeError'));
      expect(result.title, contains('android'));
      expect(result.title, isNot(contains(r'$')));
      expect(result.rootCause, 'products.first on an empty list');
    });

    test('camelCase keys are accepted as readily as snake_case', () async {
      const camel = '''
      {
        "summary": "Empty catalogue crash",
        "rootCause": "first on an empty list",
        "reproSteps": ["open the catalogue"],
        "severity": "Major"
      }
      ''';
      final client = MockClient((request) async => _chatResponse(camel));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      expect(result!.title, 'Empty catalogue crash');
      expect(result.reproSteps, ['open the catalogue']);
      expect(result.severity, 'major', reason: 'severity is case-insensitive');
    });

    test('a missing root cause is still fatal — it is the whole point',
        () async {
      const noCause = '{"title": "Something broke", "repro_steps": ["tap"]}';
      final client = MockClient((request) async => _chatResponse(noCause));

      expect(await _analyzer(client).analyse(_incident(), 'trace'), isNull);
    });

    test('HTTP 429 returns null without throwing', () async {
      final client = MockClient((request) async => http.Response('rate limited', 429));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNull);
    });

    test('HTTP 500 returns null without throwing', () async {
      final client = MockClient((request) async => http.Response('server error', 500));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNull);
    });

    test('empty choices returns null', () async {
      final client = MockClient(
        (request) async => http.Response(jsonEncode({'choices': []}), 200),
      );
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNull);
    });

    test('a slow model times out and returns null instead of hanging', () async {
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _chatResponse(_validJson);
      });
      final result = await _analyzer(client, timeout: const Duration(milliseconds: 20))
          .analyse(_incident(), 'trace');

      expect(result, isNull);
    });

    test('never throws even when the underlying client throws', () async {
      final client = MockClient((request) async => throw Exception('socket closed'));

      await expectLater(
        _analyzer(client).analyse(_incident(), 'trace'),
        completion(isNull),
      );
    });

    test('the screenshot field is never sent to the model', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _chatResponse(_validJson);
      });

      final screenshotPayload = base64Encode(List.filled(1000, 1));
      await _analyzer(client).analyse(
        _incident(context: {
          'routes': ['/home', '/cart'],
          'logs': ['tapped checkout'],
          'screenshot': screenshotPayload,
        }),
        'trace',
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      final content = (body['messages'] as List).first['content'] as String;
      expect(content, isNot(contains('screenshot')));
      expect(content, isNot(contains(screenshotPayload)));
      expect(captured!.body, isNot(contains(screenshotPayload)));
      expect(content, contains('/home -> /cart'));
      expect(content, contains('tapped checkout'));
    });

    test('the api key is sent as the configured header and never logged or thrown', () async {
      final printed = <String>[];
      final client = MockClient(
        (request) async => throw Exception('unauthorized, saw key=Bearer test-secret-key'),
      );

      Analysis? result;
      await runZoned(
        () async {
          result = await _analyzer(client).analyse(_incident(), 'trace');
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            printed.add(line);
          },
        ),
      );

      expect(result, isNull);
      expect(printed, isEmpty);
      expect(printed.any((l) => l.contains('test-secret-key')), isFalse);
    });

    test('sends the auth header name/value and api-version query param as configured', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _chatResponse(_validJson);
      });

      await _analyzer(client, apiVersion: '2024-06-01').analyse(_incident(), 'trace');

      expect(captured!.headers['Authorization'], 'Bearer test-secret-key');
      expect(captured!.url.queryParameters['api-version'], '2024-06-01');
    });
  });
}

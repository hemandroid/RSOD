import 'dart:convert';

import 'package:incident_backend/src/config.dart';
import 'package:test/test.dart';

/// A complete, valid environment map. Tests copy this and override or
/// remove individual keys rather than mutating `Platform.environment`.
Map<String, String> _validEnv() => {
      'INGEST_APP_TOKEN': 'ingest-secret-token',
      'JIRA_API_BASE': 'https://api.atlassian.com/ex/jira',
      'JIRA_CLOUD_ID': 'cloud-123',
      'JIRA_EMAIL': 'bot@example.com',
      'JIRA_API_TOKEN': 'jira-secret-token',
      'JIRA_PROJECT_KEY': 'SCRUM',
      'JIRA_BASE_URL': 'https://inspectro.atlassian.net',
      'SLACK_BOT_TOKEN': 'slack-secret-token',
      'SLACK_CHANNEL_ID': 'C123',
      'SLACK_DM_USER_ID': 'U456',
      'AI_ENDPOINT': 'https://api.groq.com/openai/v1/chat/completions',
      'AI_API_KEY': 'ai-secret-key',
      'AI_MODEL': 'llama-3.3-70b',
    };

void main() {
  group('Config.fromMap required variables', () {
    test('builds successfully when every required variable is present', () {
      final config = Config.fromMap(_validEnv());
      expect(config.ingestAppToken, 'ingest-secret-token');
      expect(config.jiraProjectKey, 'SCRUM');
      expect(config.slackChannelId, 'C123');
      expect(config.aiModel, 'llama-3.3-70b');
    });

    test('throws StateError naming every missing variable at once', () {
      final env = _validEnv()
        ..remove('JIRA_API_TOKEN')
        ..remove('SLACK_CHANNEL_ID')
        ..remove('AI_API_KEY');

      try {
        Config.fromMap(env);
        fail('expected a StateError');
      } on StateError catch (e) {
        expect(e.message, contains('JIRA_API_TOKEN'));
        expect(e.message, contains('SLACK_CHANNEL_ID'));
        expect(e.message, contains('AI_API_KEY'));
        // Must not mention variables that were actually present.
        expect(e.message, isNot(contains('JIRA_PROJECT_KEY')));
      }
    });

    test('treats a variable set to the empty string as missing', () {
      final env = _validEnv()..['INGEST_APP_TOKEN'] = '';

      expect(
        () => Config.fromMap(env),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('INGEST_APP_TOKEN'),
          ),
        ),
      );
    });
  });

  group('Config.fromMap optional defaults', () {
    test('defaults AI_AUTH_HEADER to Authorization with a Bearer value', () {
      final config = Config.fromMap(_validEnv());
      expect(config.aiAuthHeader, 'Authorization');
      // MapEntry has no value equality, so compare the parts.
      expect(config.aiAuthHeaderEntry.key, 'Authorization');
      expect(config.aiAuthHeaderEntry.value, 'Bearer ai-secret-key');
    });

    test('Azure-style api-key header carries the bare key, not Bearer', () {
      final env = _validEnv()..['AI_AUTH_HEADER'] = 'api-key';
      final config = Config.fromMap(env);
      expect(config.aiAuthHeader, 'api-key');
      expect(config.aiAuthHeaderEntry.key, 'api-key');
      expect(config.aiAuthHeaderEntry.value, 'ai-secret-key');
    });

    test('AI_API_VERSION defaults to empty', () {
      expect(Config.fromMap(_validEnv()).aiApiVersion, '');
    });

    test('AI_API_VERSION is carried through when set', () {
      final env = _validEnv()..['AI_API_VERSION'] = '2024-06-01';
      expect(Config.fromMap(env).aiApiVersion, '2024-06-01');
    });

    test('JIRA_ISSUE_TYPE defaults to Bug', () {
      expect(Config.fromMap(_validEnv()).jiraIssueType, 'Bug');
    });

    test('JIRA_ISSUE_TYPE honours an override', () {
      final env = _validEnv()..['JIRA_ISSUE_TYPE'] = 'Incident';
      expect(Config.fromMap(env).jiraIssueType, 'Incident');
    });

    test('PORT defaults to 8787', () {
      expect(Config.fromMap(_validEnv()).port, 8787);
    });

    test('PORT honours a numeric override', () {
      final env = _validEnv()..['PORT'] = '9000';
      expect(Config.fromMap(env).port, 9000);
    });

    test('a non-numeric PORT fails loudly instead of silently defaulting',
        () {
      final env = _validEnv()..['PORT'] = 'not-a-number';
      expect(() => Config.fromMap(env), throwsStateError);
    });

    test('SYMBOLS_DIR defaults to build/symbols', () {
      expect(Config.fromMap(_validEnv()).symbolsDir, 'build/symbols');
    });
  });

  group('Config computed values', () {
    test('jiraApiRoot builds the REST v3 root from base + cloud id', () {
      final config = Config.fromMap(_validEnv());
      expect(
        config.jiraApiRoot,
        'https://api.atlassian.com/ex/jira/cloud-123/rest/api/3',
      );
    });

    test('jiraBasicAuth is a complete Authorization header value', () {
      final config = Config.fromMap(_validEnv());
      // The scheme must be included: JiraFiler sends this verbatim, and bare
      // base64 makes Jira treat the request as anonymous.
      expect(config.jiraBasicAuth, startsWith('Basic '));
      final decoded = utf8.decode(
        base64Decode(config.jiraBasicAuth.substring('Basic '.length)),
      );
      expect(decoded, 'bot@example.com:jira-secret-token');
    });
  });

  group('Config trimming', () {
    test('a trailing space on a value is stripped', () {
      // Invisible in an editor, and Jira answers a padded project key with
      // "the target project doesn't exist" — an error pointing nowhere near
      // the cause.
      final env = _validEnv()
        ..['JIRA_PROJECT_KEY'] = 'SCRUM '
        ..['AI_MODEL'] = '  qwen/qwen3.8-27b  ';
      final config = Config.fromMap(env);

      expect(config.jiraProjectKey, 'SCRUM');
      expect(config.aiModel, 'qwen/qwen3.8-27b');
    });

    test('a whitespace-only value counts as missing', () {
      final env = _validEnv()..['JIRA_API_TOKEN'] = '   ';

      expect(() => Config.fromMap(env), throwsStateError);
    });

    test('a port outside 1..65535 fails loudly', () {
      expect(() => Config.fromMap(_validEnv()..['PORT'] = '0'),
          throwsStateError);
      expect(() => Config.fromMap(_validEnv()..['PORT'] = '99999'),
          throwsStateError);
    });
  });

  group('Config.toString', () {
    test('never contains a secret value', () {
      final env = _validEnv()
        ..['INGEST_APP_TOKEN'] = 'FINDME_INGEST_9f8a'
        ..['JIRA_API_TOKEN'] = 'FINDME_JIRA_1234'
        ..['SLACK_BOT_TOKEN'] = 'FINDME_SLACK_5678'
        ..['AI_API_KEY'] = 'FINDME_AI_KEY_abcd';
      final rendered = Config.fromMap(env).toString();

      expect(rendered, isNot(contains('FINDME_INGEST_9f8a')));
      expect(rendered, isNot(contains('FINDME_JIRA_1234')));
      expect(rendered, isNot(contains('FINDME_SLACK_5678')));
      expect(rendered, isNot(contains('FINDME_AI_KEY_abcd')));
      // toString should still be useful for non-secret operational config.
      expect(rendered, contains('SCRUM'));
    });
  });
}

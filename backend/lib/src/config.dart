/// Process configuration, read once at startup. A missing secret must never
/// silently become an empty string — [Config.fromMap] collects every missing
/// required variable and throws once, naming all of them.
library;

import 'dart:convert';
import 'dart:io';

class Config {
  const Config._({
    required this.ingestAppToken,
    required this.jiraApiBase,
    required this.jiraCloudId,
    required this.jiraEmail,
    required this.jiraApiToken,
    required this.jiraProjectKey,
    required this.jiraBaseUrl,
    required this.slackBotToken,
    required this.slackChannelId,
    required this.slackDmUserId,
    required this.aiEndpoint,
    required this.aiApiKey,
    required this.aiModel,
    required this.aiAuthHeader,
    required this.aiApiVersion,
    required this.jiraIssueType,
    required this.port,
    required this.symbolsDir,
  });

  /// Kept separate from [Config.fromMap] so tests never mutate global
  /// process state to exercise this class.
  factory Config.fromEnvironment() => Config.fromMap(Platform.environment);

  factory Config.fromMap(Map<String, String> env) {
    // Trim and treat "set but empty" as unset: a trailing space on a `.env`
    // line reaches Jira as a wrong project key, reported as "project doesn't
    // exist" — an error that points nowhere near the cause.
    final trimmed = <String, String>{
      for (final entry in env.entries)
        if (entry.value.trim().isNotEmpty) entry.key: entry.value.trim(),
    };
    String? present(String key) => trimmed[key];

    const requiredKeys = [
      'INGEST_APP_TOKEN',
      'JIRA_API_BASE',
      'JIRA_CLOUD_ID',
      'JIRA_EMAIL',
      'JIRA_API_TOKEN',
      'JIRA_PROJECT_KEY',
      'JIRA_BASE_URL',
      'SLACK_BOT_TOKEN',
      'SLACK_CHANNEL_ID',
      'SLACK_DM_USER_ID',
      'AI_ENDPOINT',
      'AI_API_KEY',
      'AI_MODEL',
    ];

    final missing = [
      for (final key in requiredKeys)
        if (present(key) == null) key,
    ];
    if (missing.isNotEmpty) {
      throw StateError(
        'Missing required environment variable(s): ${missing.join(', ')}',
      );
    }

    final rawPort = present('PORT');
    final port = rawPort == null ? 8787 : int.tryParse(rawPort);
    if (port == null || port < 1 || port > 65535) {
      throw StateError('PORT must be an integer in 1..65535, got "$rawPort"');
    }

    final authHeader = present('AI_AUTH_HEADER') ?? 'Authorization';

    return Config._(
      ingestAppToken: present('INGEST_APP_TOKEN')!,
      jiraApiBase: present('JIRA_API_BASE')!,
      jiraCloudId: present('JIRA_CLOUD_ID')!,
      jiraEmail: present('JIRA_EMAIL')!,
      jiraApiToken: present('JIRA_API_TOKEN')!,
      jiraProjectKey: present('JIRA_PROJECT_KEY')!,
      jiraBaseUrl: present('JIRA_BASE_URL')!,
      slackBotToken: present('SLACK_BOT_TOKEN')!,
      slackChannelId: present('SLACK_CHANNEL_ID')!,
      slackDmUserId: present('SLACK_DM_USER_ID')!,
      aiEndpoint: present('AI_ENDPOINT')!,
      aiApiKey: present('AI_API_KEY')!,
      aiModel: present('AI_MODEL')!,
      aiAuthHeader: authHeader,
      aiApiVersion: present('AI_API_VERSION') ?? '',
      jiraIssueType: present('JIRA_ISSUE_TYPE') ?? 'Bug',
      port: port,
      symbolsDir: present('SYMBOLS_DIR') ?? 'build/symbols',
    );
  }

  final String ingestAppToken;
  final String jiraApiBase;
  final String jiraCloudId;
  final String jiraEmail;
  final String jiraApiToken;
  final String jiraProjectKey;

  /// The site URL (e.g. `https://inspectro.atlassian.net`). Only for
  /// human-clickable links — API calls go through [jiraApiRoot] instead.
  final String jiraBaseUrl;

  final String slackBotToken;
  final String slackChannelId;
  final String slackDmUserId;
  final String aiEndpoint;
  final String aiApiKey;
  final String aiModel;

  /// `Authorization` for Groq/OpenAI-compatible APIs, `api-key` for Azure AI
  /// Foundry. See [aiAuthHeaderEntry] for the matching value format.
  final String aiAuthHeader;

  /// Appended as an `api-version` query parameter when non-empty; Azure
  /// requires it, Groq ignores it.
  final String aiApiVersion;

  final String jiraIssueType;
  final int port;
  final String symbolsDir;

  String get jiraApiRoot => '$jiraApiBase/$jiraCloudId/rest/api/3';

  /// Includes the `Basic` scheme on purpose: bare base64 makes Jira treat the
  /// call as anonymous and answer `400 The target project doesn't exist`,
  /// which points at the project rather than the header.
  String get jiraBasicAuth =>
      'Basic ${base64Encode(utf8.encode('$jiraEmail:$jiraApiToken'))}';

  /// When the header is `Authorization` the value must be `Bearer <key>`;
  /// Azure's `api-key` wants the bare key. Makes swapping Groq for Azure a
  /// config change, not a code change.
  MapEntry<String, String> get aiAuthHeaderEntry => MapEntry(
        aiAuthHeader,
        aiAuthHeader == 'Authorization' ? 'Bearer $aiApiKey' : aiApiKey,
      );

  /// Omits every secret field, so a stray `print(config)` can't leak one.
  @override
  String toString() => 'Config('
      'jiraApiRoot: $jiraApiRoot, '
      'jiraBaseUrl: $jiraBaseUrl, '
      'jiraProjectKey: $jiraProjectKey, '
      'jiraIssueType: $jiraIssueType, '
      'aiEndpoint: $aiEndpoint, '
      'aiModel: $aiModel, '
      'aiAuthHeader: $aiAuthHeader, '
      'port: $port, '
      'symbolsDir: $symbolsDir)';
}

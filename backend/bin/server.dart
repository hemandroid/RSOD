import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:incident_backend/src/config.dart';
import 'package:incident_backend/src/dedupe_store.dart';
import 'package:incident_backend/src/fingerprint.dart';
import 'package:incident_backend/src/groq_analyzer.dart';
import 'package:incident_backend/src/ingest_handler.dart';
import 'package:incident_backend/src/jira_filer.dart';
import 'package:incident_backend/src/pipeline.dart';
import 'package:incident_backend/src/slack_notifier.dart';
import 'package:incident_backend/src/symbolicator.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Composition root: the only place that knows which concrete implementation
/// stands behind each contract, so swapping a provider is a config change,
/// never a pipeline change.
Future<void> main() async {
  void log(String message) {
    // stderr, not stdout: container platforms treat stdout as application
    // output and stderr as diagnostics.
    stderr.writeln('${DateTime.now().toIso8601String()} $message');
  }

  final Config config;
  try {
    config = Config.fromEnvironment();
  } on StateError catch (e) {
    // Refusing to start beats starting misconfigured and filing nothing.
    stderr.writeln(e.message);
    exitCode = 78; // EX_CONFIG
    return;
  }

  final client = http.Client();

  final pipeline = IncidentPipeline(
    symbolicator: ReleaseSymbolicator(config.symbolsDir),
    analyzer: GroqAnalyzer(
      endpoint: config.aiEndpoint,
      authHeaderName: config.aiAuthHeaderEntry.key,
      authHeaderValue: config.aiAuthHeaderEntry.value,
      model: config.aiModel,
      apiVersion: config.aiApiVersion.isEmpty ? null : config.aiApiVersion,
      // Short enough that a stalled model can't hold up the ticket.
      timeout: const Duration(seconds: 20),
      client: client,
      log: log,
    ),
    filer: JiraFiler(
      apiRoot: config.jiraApiRoot,
      authHeader: config.jiraBasicAuth,
      projectKey: config.jiraProjectKey,
      issueTypeName: config.jiraIssueType,
      siteBaseUrl: config.jiraBaseUrl,
      client: client,
      log: log,
    ),
    notifier: SlackNotifier(
      botToken: config.slackBotToken,
      channelId: config.slackChannelId,
      dmUserId: config.slackDmUserId,
      client: client,
    ),
    dedupe: JsonFileDedupeStore(
      Platform.environment['DEDUPE_PATH'] ?? '.incident-dedupe.json',
    ),
    fingerprint: fingerprint,
    log: log,
  );

  final ingest = IngestHandler(
    appToken: config.ingestAppToken,
    pipeline: pipeline,
    log: log,
  );

  // 0.0.0.0, not localhost: the emulator reaches the host as 10.0.2.2, and a
  // container's loopback is unreachable from outside it either way.
  final server = await shelf_io.serve(ingest.handler, '0.0.0.0', config.port);
  log('listening on http://${server.address.host}:${server.port}');
  log('jira ${config.jiraProjectKey} · model ${config.aiModel} · '
      'symbols ${config.symbolsDir}');

  Future<void> shutdown(ProcessSignal signal) async {
    log('$signal received, draining');
    await server.close();
    // Accepted incidents were already acked to the app and dropped from its
    // queue, so finish the work here rather than losing them.
    await ingest.idle;
    client.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
}

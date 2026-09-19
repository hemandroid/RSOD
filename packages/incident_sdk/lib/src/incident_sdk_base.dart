import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'build_identity.dart';
import 'collectors/collector.dart';
import 'collectors/device_collector.dart';
import 'collectors/log_collector.dart';
import 'collectors/screenshot_collector.dart';
import 'crypto/incident_cipher.dart';
import 'incident_capture.dart';
import 'incident_queue.dart';
import 'upload/incident_uploader.dart';
import 'upload/transport.dart';
import 'watchdog/ui_watchdog.dart';

/// Entry point. See the library doc for the integration snippet.
class IncidentSDK {
  static IncidentCapture? _capture;
  static IncidentQueue? _queue;
  static IncidentUploader? _uploader;
  static UiWatchdog? _watchdog;

  static final IncidentLog _log = IncidentLog();

  /// Records a breadcrumb on the buffer attached to every incident by
  /// default: `IncidentSDK.log('checkout: applied coupon SAVE10')`.
  static void log(String message, {LogLevel level = LogLevel.info}) =>
      _log.log(message, level: level);

  static bool get isInitialized => _capture != null;

  /// Starts capturing. Call before [runApp]; safe to call twice.
  ///
  /// Installs the error hooks, starts the UI-stall watchdog and starts the
  /// background uploader. Hooks go in synchronously so a crash during
  /// startup is still caught; the storage directory and encryption key
  /// resolve in the background, and the queue moves itself and its backlog
  /// once they do. One queue and one capture exist for the life of the app,
  /// mutated in place rather than replaced — a guarded zone opened during
  /// startup keeps a reference and must not be left writing to the
  /// abandoned temp directory.
  ///
  /// [endpoint] is the full ingest URL; nothing here appends a path.
  ///
  /// [collectors] run, in order, on every capture (see
  /// [buildCollectorRegistry]) and are the only extension point new context
  /// sources need. The two that need nothing from the host — device info
  /// and [log] — are added on top of that list unless
  /// [includeDefaultCollectors] is false; an explicit collector of the same
  /// name wins, so a host that supplies its own `device` or `logs` never
  /// ends up with both.
  ///
  /// Pass [screenshots] to attach a screenshot of the failing frame. It
  /// cannot be an ordinary collector: a frame takes a frame to capture, so
  /// the image arrives after the incident is already on disk and is
  /// amended in afterwards. The host must also wrap the app root in
  /// `RepaintBoundary(key: screenshots.boundaryKey, ...)` — the one thing
  /// this call cannot do for it.
  static void init({
    required String endpoint,
    required String appToken,
    List<IncidentCollector> collectors = const [],
    bool includeDefaultCollectors = true,
    ScreenshotCollector? screenshots,
    int maxPending = 50,
    bool enableUiWatchdog = true,
    Duration uiWatchdogThreshold = const Duration(seconds: 5),
    bool allowInsecureEndpoint = false,
  }) {
    if (_capture != null) return;

    final ingest = _validatedEndpoint(
      endpoint,
      appToken,
      allowInsecureEndpoint: allowInsecureEndpoint,
    );

    // Before anything builds a collector: DeviceCollector's platform channel
    // needs a binding, and a model resolved too early is silently lost.
    WidgetsFlutterBinding.ensureInitialized();

    // Temp dir first so the hooks can be live immediately; the queue moves to
    // the durable directory as soon as path_provider answers.
    final queue = IncidentQueue(
      dir: Directory('${Directory.systemTemp.path}/incidents'),
      maxPending: maxPending,
    );
    _queue = queue;
    _capture = IncidentCapture(
      queue: queue,
      collectContext: buildCollectorRegistry(_registry(
        collectors,
        includeDefaultCollectors: includeDefaultCollectors,
      )),
      onIncidentQueued: screenshots == null
          ? null
          : (id) => unawaited(screenshots
              .captureSoon()
              .then((entry) {
                if (entry != null) queue.amend(id, {'screenshot': entry});
              })
              // Fire-and-forget on the crash path: a screenshot that fails
              // must not become an unhandled rejection.
              .catchError((Object _) {})),
    )..install();

    // Off the crash path from here. Each worker is guarded on its own: the
    // hooks are already live and `_capture` is already set, so a throw here
    // would both escape into the host's `main()` and make every later
    // `init()` return early — capturing forever, shipping nothing.
    _startQuietly('uploader', () {
      // The uploader holds the same queue object the hooks write to, so it
      // keeps draining across the move to the durable directory.
      _uploader = IncidentUploader(
        queue: queue,
        transport: HttpIncidentTransport(endpoint: ingest, appToken: appToken),
      )..start();
    });

    if (enableUiWatchdog) {
      _startQuietly('watchdog', () {
        _watchdog = UiWatchdog(
          onStall: _capture!.reportStall,
          threshold: uiWatchdogThreshold,
        )..start();
      });
    }

    resolveIncidentCipher().then(queue.attachCipher).catchError((Object e) {
      // Queued incidents stay in plaintext. Say so: a device that cannot
      // reach its keystore is one where this matters most.
      _selfNote(
        'could not resolve the data key ($e). Queued incidents remain '
        'unencrypted on disk.',
      );
    });

    getApplicationSupportDirectory()
        .then((dir) => queue.moveTo(Directory('${dir.path}/incidents')))
        .catchError((_) {
      // Stay in the temp directory. Incidents survive the crash but not
      // necessarily a device reboot, which beats losing them outright.
      return null;
    });

    if (BuildIdentity.isUnidentified) {
      _selfNote(
        'COMMIT_SHA is not set. Release stack traces will arrive '
        'unsymbolicatable. Build with '
        '--dart-define=COMMIT_SHA=\$(git rev-parse HEAD).',
      );
    }
  }

  /// Report a handled failure that still deserves a ticket.
  static void report(Object error, StackTrace stack, {String? context}) =>
      _capture?.report(error, stack, context: context);

  /// Run [body] inside a guarded zone so async errors are captured too.
  ///
  /// Not `_capture?.runGuarded(body) ?? body()`: for a `void` body that
  /// expression runs [body] a second time, unguarded, because a `void` result
  /// is indistinguishable from null.
  static R? runGuarded<R>(R Function() body) {
    final capture = _capture;
    return capture == null ? body() : capture.runGuarded(body);
  }

  /// Incidents captured but not yet uploaded.
  static int get pendingCount => _queue?.length ?? 0;

  @visibleForTesting
  static void resetForTest() {
    // Both own live timers that would otherwise leak into the next test.
    _uploader?.stop();
    _watchdog?.stop();
    _capture = null;
    _queue = null;
    _uploader = null;
    _watchdog = null;
  }

  /// The SDK reporting on itself. `debugPrint` is compiled out of release —
  /// the one build that matters here — so anything the SDK needs to say about
  /// its own health also goes into the log ring, which rides along inside
  /// every incident that does get through.
  static void _selfNote(String message) {
    _log.log('incident_sdk: $message', level: LogLevel.error);
    debugPrint('incident_sdk: $message');
  }

  static void _startQuietly(String what, void Function() start) {
    try {
      start();
    } catch (e) {
      _selfNote('could not start the $what ($e).');
    }
  }

  /// [collectors] plus whatever the host did not supply itself. Merged by
  /// name so a duplicate registration can never reach
  /// [buildCollectorRegistry], which treats one as a bug.
  static List<IncidentCollector> _registry(
    List<IncidentCollector> collectors, {
    required bool includeDefaultCollectors,
  }) {
    // Screenshots are not in this list: a frame takes a frame to capture,
    // so it can never be ready for this synchronous, every-incident
    // snapshot. It reaches its one matching incident afterwards, via
    // `screenshots.captureSoon()` + `queue.amend()` below — registering
    // `screenshots.collector` here would instead attach the same stale,
    // unrelated frame to every incident captured after it.
    final extras = <IncidentCollector>[
      if (includeDefaultCollectors) ...[
        DeviceCollector.capture().collector,
        _log.collector,
      ],
    ];
    final names = collectors.map((c) => c.name).toSet();
    final registry = [...collectors];
    for (final extra in extras) {
      if (names.add(extra.name)) registry.add(extra);
    }
    return registry;
  }

  /// Fail loudly rather than ship a build that reports nowhere. The
  /// uploader swallows its own failures by design, so a bad endpoint or an
  /// empty token would otherwise show up only as an empty dashboard.
  static Uri _validatedEndpoint(
    String endpoint,
    String appToken, {
    required bool allowInsecureEndpoint,
  }) {
    if (appToken.trim().isEmpty) {
      throw ArgumentError.value(
          appToken, 'appToken', 'incident_sdk: appToken must not be empty');
    }
    if (endpoint.trim().isEmpty) {
      throw ArgumentError.value(
          endpoint, 'endpoint', 'incident_sdk: endpoint must not be empty');
    }
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null ||
        !(uri.isScheme('https') || uri.isScheme('http')) ||
        uri.host.isEmpty) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'incident_sdk: endpoint must be an absolute http(s) URL with a host',
      );
    }
    // Everything an incident carries — the app token, stack traces, logs,
    // network metadata, a screenshot of the user's screen — would cross the
    // wire in the clear. A host that genuinely wants that (a local sink on a
    // dev machine) has to say so by name.
    if (uri.isScheme('http') && !allowInsecureEndpoint) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'incident_sdk: endpoint must be https. Pass '
            'allowInsecureEndpoint: true to send incidents in the clear.',
      );
    }
    return uri;
  }
}

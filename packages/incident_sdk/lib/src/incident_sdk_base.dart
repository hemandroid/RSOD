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
  /// Hooks install synchronously so a startup crash is still caught, while
  /// storage and the encryption key resolve in the background; the queue
  /// and capture are mutated in place rather than replaced, since a guarded
  /// zone from startup keeps its own reference to them.
  ///
  /// [endpoint] is the full ingest URL, with no path appended. [collectors]
  /// run on every capture; device info and [log] are added by default, and
  /// an explicit collector of the same name always wins.
  ///
  /// [screenshots] can't be an ordinary collector, since a frame takes a
  /// frame to capture — it's amended onto the incident afterwards. Wrap the
  /// app root in `RepaintBoundary(key: screenshots.boundaryKey, ...)`.
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

    // DeviceCollector's platform channel needs a binding, or a model
    // resolved too early is silently lost.
    WidgetsFlutterBinding.ensureInitialized();

    // Temp dir first so the hooks can be live immediately; the queue moves
    // to the durable directory once path_provider answers.
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
              // A failed screenshot must not become an unhandled rejection.
              .catchError((Object _) {})),
    )..install();

    // Off the crash path from here: `_capture` is already live, so each
    // worker is guarded individually rather than letting a throw here
    // escape into the host's `main()`.
    _startQuietly('uploader', () {
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
      // Queued incidents stay in plaintext — worth surfacing loudly.
      _selfNote(
        'could not resolve the data key ($e). Queued incidents remain '
        'unencrypted on disk.',
      );
    });

    getApplicationSupportDirectory()
        .then((dir) => queue.moveTo(Directory('${dir.path}/incidents')))
        .catchError((_) {
      // Stay in the temp directory: survives the crash, if not a reboot.
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

  /// `debugPrint` is compiled out of release, so this also goes into the log
  /// ring, which rides along inside every incident that gets through.
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
    // Screenshots aren't in this list: a frame takes a frame to capture, so
    // it could never be ready for this synchronous snapshot — registering
    // it here would attach the same stale frame to every later incident.
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
    // Everything an incident carries (token, stack traces, a screenshot)
    // would cross the wire in the clear; a host that wants that has to opt in.
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

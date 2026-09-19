/// Captures production Flutter failures with full context and ships them to
/// an incident backend, so a user never has to report a bug by leaving a
/// review or emailing support.
///
/// Integration is one call, before `runApp`:
///
/// ```dart
/// IncidentSDK.init(
///   endpoint: 'https://incidents.example.com/ingest',
///   appToken: '...',
/// );
/// ```
///
/// That installs the error hooks, starts the UI-stall watchdog and the
/// background uploader, and attaches device info plus whatever
/// [IncidentSDK.log] recorded to every incident.
///
/// The rest is opt-in, because each piece needs wiring only the host can do
/// — a navigator observer, an HTTP client swap, a `RepaintBoundary`:
///
/// ```dart
/// final routes = RouteHistoryCollector();
/// final network = NetworkCollector();
/// final client = IncidentHttpClient(network, inner: http.Client());
/// final screenshots = ScreenshotCollector();
///
/// IncidentSDK.init(
///   endpoint: 'https://incidents.example.com/ingest',
///   appToken: '...',
///   collectors: [routes.collector, network.collector],
///   screenshots: screenshots,
/// );
///
/// runApp(MaterialApp(
///   navigatorObservers: [routes],
///   home: RepaintBoundary(key: screenshots.boundaryKey, child: const Home()),
/// ));
/// ```
///
/// Wrap anything sensitive inside that boundary in [IncidentMask] — nothing
/// here finds sensitive UI on its own.
library;

export 'src/build_identity.dart';
export 'src/collectors/collector.dart';
export 'src/collectors/device_collector.dart';
export 'src/collectors/log_collector.dart';
export 'src/collectors/network_collector.dart';
export 'src/collectors/network_interceptor.dart';
export 'src/collectors/route_collector.dart';
export 'src/collectors/screenshot_collector.dart';
export 'src/crypto/incident_cipher.dart';
export 'src/incident.dart';
export 'src/incident_capture.dart';
export 'src/incident_queue.dart';
export 'src/incident_sdk_base.dart';
export 'src/upload/incident_uploader.dart';
export 'src/upload/transport.dart';
export 'src/watchdog/ui_watchdog.dart';
// `show`: the same file declares `incidentMaskingActive`, which only
// ScreenshotCollector may write. A host flipping it would paint masks over
// the live screen.
export 'src/widgets/incident_mask.dart' show IncidentMask;

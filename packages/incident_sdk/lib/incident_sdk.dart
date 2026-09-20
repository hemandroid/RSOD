/// Captures production Flutter failures with full context and ships them to
/// an incident backend.
///
/// Call [IncidentSDK.init] before `runApp`. Collectors, an HTTP client swap
/// and screenshots are opt-in, since each needs wiring only the host app can
/// do. Wrap anything sensitive in [IncidentMask] — nothing here finds
/// sensitive UI on its own.
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
// `show`: that file also declares `incidentMaskingActive`, which only
// ScreenshotCollector may write.
export 'src/widgets/incident_mask.dart' show IncidentMask;

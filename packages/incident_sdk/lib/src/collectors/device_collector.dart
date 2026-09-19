import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import '../build_identity.dart';
import 'collector.dart';

/// Device and build context, read once and cached.
///
/// Everything except the hardware model comes from `dart:io` synchronously
/// at construction. The model needs a platform channel, so it is resolved
/// once in the background and written into the same cached map when it
/// arrives — [collector] stays a plain map read, with nothing to await or
/// fail at on the crash path. A device that never answers simply has no
/// `model` key.
///
/// `processMemoryBytes` is this process's resident set size, not
/// system-wide available memory.
///
/// Deliberately excludes [Platform.environment] and [Platform.localHostname]
/// — both routinely carry a real person's name (a home directory path, a
/// device named "Jane's iPhone"). A model identifier does not.
class DeviceCollector {
  DeviceCollector._(this._data);

  final Map<String, dynamic> _data;

  /// Reads everything once. Call at init and keep the instance for the
  /// app's lifetime — [collector] only ever replays this snapshot, it never
  /// re-reads the platform.
  factory DeviceCollector.capture() {
    final data = <String, dynamic>{
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'locale': Platform.localeName,
      'numberOfProcessors': Platform.numberOfProcessors,
      'processMemoryBytes': ProcessInfo.currentRss,
      'appVersion': BuildIdentity.appVersion,
      'commitSha': BuildIdentity.commitSha,
    };
    // Not awaited: `IncidentSDK.init` is synchronous so the hooks are live
    // before the first frame. A crash before this resolves loses the model
    // field and nothing else.
    unawaited(_resolveModel().then((model) {
      if (model != null) data['model'] = model;
    }));
    return DeviceCollector._(data);
  }

  static Future<String?> _resolveModel() async {
    try {
      return modelFrom((await DeviceInfoPlugin().deviceInfo).data);
    } catch (_) {
      // No plugin, no channel, an unparseable payload: all the same here.
      return null;
    }
  }

  /// Best available hardware identifier in a `device_info_plus` payload, or
  /// null for a payload that does not carry one.
  @visibleForTesting
  static String? modelFrom(Map<String, dynamic> data) {
    // iOS puts a marketing name in `model` ("iPhone") and the real hardware
    // in `utsname.machine` ("iPhone14,2").
    final utsname = data['utsname'];
    // `is Map`, not a cast: a wrong type off a platform channel must cost
    // the model field, not throw out of a collector.
    final machine = utsname is Map ? utsname['machine'] : null;
    if (machine is String && machine.trim().isNotEmpty) return machine;
    // Android/macOS: `model`. Linux: `prettyName`. Windows: `productName`.
    for (final key in const ['model', 'prettyName', 'productName']) {
      final value = data[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  /// This snapshot, registered under the name `device`. A copy: the model
  /// lands in [_data] from a background future, and a caller must not be
  /// handed a map that changes under it.
  IncidentCollector get collector =>
      (name: 'device', collect: () => Map<String, dynamic>.of(_data));
}

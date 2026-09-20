import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import '../build_identity.dart';
import 'collector.dart';

/// Device and build context, read once and cached.
///
/// `processMemoryBytes` is this process's RSS, not system-wide memory.
///
/// Deliberately excludes [Platform.environment] and [Platform.localHostname]
/// — both routinely carry a real person's name.
class DeviceCollector {
  DeviceCollector._(this._data);

  final Map<String, dynamic> _data;

  /// Call once at init; [collector] only replays this snapshot.
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
    // Not awaited: init must stay synchronous. A crash before this
    // resolves just loses the model field.
    unawaited(_resolveModel().then((model) {
      if (model != null) data['model'] = model;
    }));
    return DeviceCollector._(data);
  }

  static Future<String?> _resolveModel() async {
    try {
      return modelFrom((await DeviceInfoPlugin().deviceInfo).data);
    } catch (_) {
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
    // `is Map`, not a cast: a bad platform payload should cost the model
    // field, not throw.
    final machine = utsname is Map ? utsname['machine'] : null;
    if (machine is String && machine.trim().isNotEmpty) return machine;
    // Android/macOS: `model`. Linux: `prettyName`. Windows: `productName`.
    for (final key in const ['model', 'prettyName', 'productName']) {
      final value = data[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  /// Registered under `device`. Returns a copy since [_data] can still be
  /// mutated by the background model resolution.
  IncidentCollector get collector =>
      (name: 'device', collect: () => Map<String, dynamic>.of(_data));
}

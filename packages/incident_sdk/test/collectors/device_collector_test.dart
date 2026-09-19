import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incident_sdk/src/build_identity.dart';
import 'package:incident_sdk/src/collectors/device_collector.dart';

/// The channel `device_info_plus` talks over. Faked here rather than
/// injected, because the point of these tests is that the *real* collector
/// survives whatever that channel does — including not answering at all.
const _deviceInfoChannel = MethodChannel('dev.fluttercommunity.plus/device_info');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void mockDeviceInfo(Map<String, dynamic>? Function() respond) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            _deviceInfoChannel, (call) async => respond());
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_deviceInfoChannel, null));
  }

  test('reports platform and build identity under the device key', () {
    final data = DeviceCollector.capture().collector.collect();

    expect(data['os'], Platform.operatingSystem);
    expect(data['osVersion'], Platform.operatingSystemVersion);
    expect(data['locale'], Platform.localeName);
    expect(data['numberOfProcessors'], Platform.numberOfProcessors);
    expect(data['processMemoryBytes'], isA<int>());
    expect(data['appVersion'], BuildIdentity.appVersion);
    expect(data['commitSha'], BuildIdentity.commitSha);
  });

  test('never captures environment variables or the device hostname', () {
    final data = DeviceCollector.capture().collector.collect();

    expect(data.containsKey('environment'), isFalse);
    expect(data.containsKey('localHostname'), isFalse);
    expect(data.values, isNot(contains(Platform.environment)));
  });

  test('collect() replays the same cached values on repeated calls', () {
    final collector = DeviceCollector.capture();
    expect(collector.collector.collect(), collector.collector.collect());
  });

  test('picks the hardware model out of each platform\'s payload', () {
    // The shapes `device_info_plus` actually produces, per platform.
    expect(DeviceCollector.modelFrom({'model': 'Pixel 7'}), 'Pixel 7');
    expect(DeviceCollector.modelFrom({'model': 'MacBookPro18,3'}),
        'MacBookPro18,3');
    expect(DeviceCollector.modelFrom({'prettyName': 'Ubuntu 24.04'}),
        'Ubuntu 24.04');
    expect(DeviceCollector.modelFrom({'productName': 'Windows 11 Pro'}),
        'Windows 11 Pro');
  });

  test('prefers the iOS hardware identifier over its marketing name', () {
    expect(
      DeviceCollector.modelFrom({
        'model': 'iPhone',
        'utsname': {'machine': 'iPhone14,2'},
      }),
      'iPhone14,2',
      reason: '"iPhone" identifies no device a backend can chart',
    );
  });

  test('a payload with no model at all yields null, never a throw', () {
    expect(DeviceCollector.modelFrom(const {}), isNull);
    expect(DeviceCollector.modelFrom(const {'model': '  '}), isNull);
    expect(DeviceCollector.modelFrom(const {'model': 42}), isNull);
    expect(DeviceCollector.modelFrom(const {'utsname': 'not a map'}), isNull);
  });

  test('a device model that never arrives costs the field, not the context',
      () async {
    mockDeviceInfo(() => throw PlatformException(code: 'unavailable'));

    final collector = DeviceCollector.capture().collector;
    await pumpEventQueue();

    expect(collector.collect().containsKey('model'), isFalse);
    expect(collector.collect()['os'], Platform.operatingSystem,
        reason: 'everything the platform could answer is still there');
  });

  test('collect() before the model resolves still returns a full snapshot',
      () {
    mockDeviceInfo(() => {'model': 'Pixel 7'});

    // No pumpEventQueue: this is the crash-during-startup case, where the
    // channel has not answered yet. It must be a plain map read either way.
    final data = DeviceCollector.capture().collector.collect();

    expect(data['os'], Platform.operatingSystem);
    expect(data.containsKey('model'), isFalse);
  });
}

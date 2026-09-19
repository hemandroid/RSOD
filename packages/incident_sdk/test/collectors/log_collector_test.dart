import 'package:flutter_test/flutter_test.dart';
import 'package:incident_sdk/src/collectors/log_collector.dart';

List<Map<String, dynamic>> _entries(IncidentLog log) =>
    (log.collector.collect()['entries'] as List).cast<Map<String, dynamic>>();

void main() {
  test('records a message with level and timestamp', () {
    final log = IncidentLog();
    log.log('checkout started', level: LogLevel.warning);

    final entries = _entries(log);
    expect(entries, hasLength(1));
    expect(entries.single['message'], 'checkout started');
    expect(entries.single['level'], 'warning');
    expect(entries.single['at'], isA<String>());
  });

  test('drops the oldest entry once maxEntries is reached', () {
    final log = IncidentLog(maxEntries: 2);
    log.log('one');
    log.log('two');
    log.log('three');

    final entries = _entries(log);
    expect(entries, hasLength(2));
    expect(entries.map((e) => e['message']), ['two', 'three']);
  });

  test('drops oldest entries once maxBytes is reached even under the entry cap',
      () {
    final log = IncidentLog(maxEntries: 1000, maxBytes: 20);
    log.log('a' * 15); // 15 bytes
    log.log('b' * 15); // pushes total past 20 bytes

    final entries = _entries(log);
    expect(entries, hasLength(1),
        reason: 'the byte cap must bound the buffer independently of the '
            'entry-count cap');
    expect(entries.single['message'], 'b' * 15);
  });

  test('never exceeds either cap under a flood of writes', () {
    final log = IncidentLog(maxEntries: 10, maxBytes: 200);
    for (var i = 0; i < 500; i++) {
      log.log('message number $i with some padding to add bytes');
    }

    final entries = _entries(log);
    expect(entries.length, lessThanOrEqualTo(10));
    final totalBytes =
        entries.fold<int>(0, (sum, e) => sum + (e['message'] as String).length);
    expect(totalBytes, lessThanOrEqualTo(200));
  });

  test('log() never throws', () {
    final log = IncidentLog();
    expect(() => log.log(''), returnsNormally);
  });
}

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incident_sdk/src/collectors/route_collector.dart';

Route<void> _route(String name) =>
    PageRouteBuilder<void>(
      settings: RouteSettings(name: name),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
    );

void main() {
  test('records pushes with a route name and timestamp', () {
    final observer = RouteHistoryCollector();
    observer.didPush(_route('/checkout'), null);

    final history =
        observer.collector.collect()['history'] as List<Map<String, dynamic>>;
    expect(history, hasLength(1));
    expect(history.single['route'], '/checkout');
    expect(history.single['event'], 'push');
    expect(history.single['at'], isA<String>());
  });

  test('drops the oldest entry once maxEntries is reached', () {
    final observer = RouteHistoryCollector(maxEntries: 2);

    observer.didPush(_route('/a'), null);
    observer.didPush(_route('/b'), null);
    observer.didPush(_route('/c'), null);

    final history =
        observer.collector.collect()['history'] as List<Map<String, dynamic>>;
    expect(history, hasLength(2));
    expect(history.map((e) => e['route']), ['/b', '/c']);
  });

  test('never grows past maxEntries under a long navigation history', () {
    final observer = RouteHistoryCollector(maxEntries: 5);

    for (var i = 0; i < 200; i++) {
      observer.didPush(_route('/page$i'), null);
    }

    final history =
        observer.collector.collect()['history'] as List<Map<String, dynamic>>;
    expect(history, hasLength(5));
    expect(history.last['route'], '/page199');
  });

  test('does not capture route arguments', () {
    final observer = RouteHistoryCollector();
    observer.didPush(
      PageRouteBuilder<void>(
        settings: const RouteSettings(
          name: '/user',
          arguments: {'email': 'jane@example.com'},
        ),
        pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
      null,
    );

    final entry = (observer.collector.collect()['history'] as List).single
        as Map<String, dynamic>;
    expect(entry.containsKey('arguments'), isFalse);
    expect(entry.values, isNot(contains('jane@example.com')));
  });
}

import 'dart:collection';

import 'package:flutter/widgets.dart';

import 'collector.dart';

/// Keeps the last [maxEntries] navigation events with timestamps.
///
/// Only [Route.settings.name] is kept, never `settings.arguments` — those
/// are arbitrary app objects that routinely carry PII.
///
/// Register the instance as a `NavigatorObserver` and pass [collector] to
/// `IncidentSDK.init`.
class RouteHistoryCollector extends NavigatorObserver {
  RouteHistoryCollector({this.maxEntries = 20});

  final int maxEntries;
  final _history = Queue<Map<String, dynamic>>();

  /// This observer's output, registered under the name `routes`.
  IncidentCollector get collector => (
        name: 'routes',
        collect: () => {'history': _history.toList(growable: false)},
      );

  void _record(String event, Route<dynamic>? route) {
    _history.add({
      'event': event,
      'route': route?.settings.name ?? '/',
      'at': DateTime.now().toIso8601String(),
    });
    while (_history.length > maxEntries) {
      _history.removeFirst();
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _record('push', route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _record('pop', route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _record('replace', newRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _record('remove', route);
}

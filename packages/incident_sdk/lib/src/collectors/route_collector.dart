import 'dart:collection';

import 'package:flutter/widgets.dart';

import 'collector.dart';

/// Keeps the last [maxEntries] navigation events with timestamps — the "how
/// it occurred" trail an AI turns into reproduction steps.
///
/// Only [Route.settings.name] is kept, never `settings.arguments`: arguments
/// are arbitrary app objects and routinely carry exactly the PII (emails,
/// tokens, user records) this SDK must not capture by default.
///
/// Register the instance as a `NavigatorObserver` and pass [collector] to
/// `IncidentSDK.init`:
///
/// ```dart
/// final routeHistory = RouteHistoryCollector();
/// MaterialApp(navigatorObservers: [routeHistory], ...);
/// IncidentSDK.init(..., collectors: [routeHistory.collector]);
/// ```
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
    // Bounded on every write: no crash-loop or deep navigation stack can
    // grow this past maxEntries.
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

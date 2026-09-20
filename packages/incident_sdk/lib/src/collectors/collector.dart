import 'package:flutter/foundation.dart';

/// A named unit of context, gathered synchronously when an incident is
/// captured.
///
/// A record, not a class: every collector is exactly "a name and a
/// callback", so a class hierarchy would only be extended once per
/// collector.
typedef IncidentCollector = ({
  String name,
  Map<String, dynamic> Function() collect,
});

/// Runs every collector and merges their output under its own name.
///
/// Isolation is per-collector: a throwing collector loses only its own
/// entry, never the whole incident or other collectors' output.
Map<String, dynamic> Function() buildCollectorRegistry(
  List<IncidentCollector> collectors,
) {
  assert(
    collectors.map((c) => c.name).toSet().length == collectors.length,
    'incident_sdk: two collectors share a name '
    '(${collectors.map((c) => c.name).toList()}). Names are the keys of an '
    'incident\'s context map, so one would silently replace the other. '
    'Rename one.',
  );
  return () {
    final context = <String, dynamic>{};
    for (final collector in collectors) {
      try {
        // Release fallback for the debug-only assert above: a colliding
        // name gets suffixed (`route#2`) instead of throwing, so a name
        // typo can't take down production incident reporting.
        context[freeCollectorKey(context, collector.name)] =
            collector.collect();
      } catch (e) {
        context[freeCollectorKey(context, collector.name)] = {
          '_error': e.toString()
        };
      }
    }
    return context;
  };
}

/// [name], or the first `name#n` not already taken. The release-mode half
/// of the duplicate-name guard; see [buildCollectorRegistry].
@visibleForTesting
String freeCollectorKey(Map<String, dynamic> context, String name) {
  if (!context.containsKey(name)) return name;
  var n = 2;
  while (context.containsKey('$name#$n')) {
    n++;
  }
  return '$name#$n';
}

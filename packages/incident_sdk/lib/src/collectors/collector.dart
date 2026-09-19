import 'package:flutter/foundation.dart';

/// A named unit of context, gathered synchronously when an incident is
/// captured.
///
/// This is a record, not an interface, because a collector is never more
/// than "a name and a callback" — there is exactly one shape any collector
/// takes, so a class hierarchy would exist only to be extended once per
/// collector (route history, logs, device info, and whatever comes next).
/// Adding a collector means constructing one of these and adding it to the
/// list passed to `IncidentSDK.init` — no other file changes, which is the
/// property the acceptance test for this package proves.
typedef IncidentCollector = ({
  String name,
  Map<String, dynamic> Function() collect,
});

/// Runs every collector and merges their output under its own name.
///
/// Isolation is per-collector: a collector that throws loses only its own
/// entry — replaced with an error marker — never the incident being
/// captured and never another collector's output. [IncidentCapture] already
/// has a catch-all around the whole context callback, but without per-entry
/// isolation here, the first broken collector in the list would take every
/// collector after it down with it.
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
        // Release fallback for the collision the assert catches in debug: a
        // colliding name gets a suffixed key (`route#2`) so both
        // collectors' data survive. Throwing here would mean a name typo
        // takes down production incident reporting.
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

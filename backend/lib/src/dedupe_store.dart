/// Remembers fingerprint -> Jira issue key across a backend restart, so
/// tapping the same broken button repeatedly files one ticket, not several.
library;

import 'dart:convert';
import 'dart:io';

import 'contracts.dart';

/// A seam so tests can exercise "file missing", "file corrupt" and "write
/// interrupted" without touching the real filesystem.
abstract class DedupeFileSystem {
  /// Contents of the file at [path], or null if missing/unreadable.
  String? read(String path);

  /// Replaces the contents of [path] with [contents] as one atomic step:
  /// a process killed mid-call must leave [path] either fully old or fully
  /// new, never partially written.
  void writeAtomic(String path, String contents);
}

class _IoDedupeFileSystem implements DedupeFileSystem {
  const _IoDedupeFileSystem();

  @override
  String? read(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      return file.readAsStringSync();
    } catch (_) {
      return null;
    }
  }

  @override
  void writeAtomic(String path, String contents) {
    // Write to a sibling temp file, then rename over the real path: rename
    // is atomic, so a kill never leaves a half-written file behind.
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(contents, flush: true);
    tmp.renameSync(path);
  }
}

/// In-memory map persisted to a small JSON file, so a rehearsal-to-live
/// restart doesn't forget which fingerprints already have a ticket.
class JsonFileDedupeStore implements DedupeStore {
  JsonFileDedupeStore(
    this._path, {
    DedupeFileSystem? fileSystem,
    int capacity = 200,
  })  : _fs = fileSystem ?? const _IoDedupeFileSystem(),
        _capacity = capacity {
    _load();
  }

  final String _path;
  final DedupeFileSystem _fs;

  /// Caps the file so an unattended demo can't grow it forever. Eviction is
  /// FIFO by first-seen fingerprint (Dart's `Map` preserves insertion order).
  final int _capacity;

  final Map<String, String> _entries = {};

  void _load() {
    final raw = _fs.read(_path);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is String) {
          _entries[key] = value;
        }
      }
    } catch (_) {
      // Truncated or corrupt JSON: an empty store costs one duplicate
      // ticket at worst, which beats a backend that refuses to start.
    }
  }

  @override
  Future<String?> lookup(String fingerprint) async => _entries[fingerprint];

  @override
  Future<void> remember(String fingerprint, String issueKey) async {
    _entries[fingerprint] = issueKey;
    while (_entries.length > _capacity) {
      _entries.remove(_entries.keys.first);
    }
    // Off the event loop: the write only has to land before the next
    // restart, not before the next request.
    await Future(_persist);
  }

  void _persist() {
    try {
      _fs.writeAtomic(_path, jsonEncode(_entries));
    } catch (_) {
      // Loses durability, but the in-memory map is unaffected.
    }
  }
}

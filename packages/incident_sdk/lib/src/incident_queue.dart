import 'dart:convert';
import 'dart:io';

import 'crypto/incident_cipher.dart';
import 'incident.dart';

/// Disk-backed queue of incidents awaiting upload.
///
/// The crash path calls [enqueueSync] and nothing else — no network, no
/// async, no allocation beyond the payload, because a crashing app may not
/// survive long enough for a `Future` to complete. Everything else
/// (draining, deleting) runs later, off the crash path.
class IncidentQueue {
  /// Oldest incidents are dropped past this count, so a crash loop can't
  /// fill a user's storage.
  final int maxPending;

  /// Incidents larger than this are dropped rather than truncated: a partial
  /// stack trace symbolicates to nonsense.
  final int maxBytes;

  /// Mutable because the queue outlives its first directory: see [moveTo].
  Directory get dir => _dir;
  Directory _dir;

  /// Null until secure storage answers. See [attachCipher].
  IncidentCipher? _cipher;

  IncidentQueue({
    required Directory dir,
    this.maxPending = 50,
    this.maxBytes = 512 * 1024,
  }) : _dir = dir;

  /// Call as soon as [resolveIncidentCipher] completes. Policy: write
  /// plaintext until the key resolves, then encrypt — buffering in memory
  /// instead would lose exactly the startup crashes worth having. The
  /// resulting plaintext window stays bounded only because [moveTo] sweeps
  /// abandoned directories too.
  void attachCipher(IncidentCipher cipher) {
    _cipher = cipher;
    _deleteOrphanedWrites();
    _encryptPlaintextBacklog();
  }

  /// Repoints the queue at [destination] and brings everything already
  /// queued with it. Startup writes to a temp directory so the crash handler
  /// is live before `path_provider` answers; the queue moves rather than
  /// being replaced, so a capture or guarded zone holding a reference
  /// follows along. The sweep runs even with nothing to move, since a
  /// previous launch can leave plaintext behind in the destination itself.
  void moveTo(Directory destination) {
    final previous = _dir;
    if (previous.path != destination.path) {
      _dir = destination;
      if (previous.existsSync()) _drain(previous);
    }
    _encryptPlaintextBacklog();
  }

  void _drain(Directory previous) {
    try {
      if (!_dir.existsSync()) _dir.createSync(recursive: true);
      for (final f in previous.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        // A `.tmp` is a write that never completed; see
        // [_deleteOrphanedWrites].
        if (!name.endsWith('.json') && !name.endsWith('.enc')) {
          _deleteQuietly(f);
          continue;
        }
        _moveQuietly(f, '${_dir.path}/$name');
      }
      // Not recursive: succeeds only once empty, so a file we failed to move
      // is left for the next launch instead of deleted with the directory.
      previous.deleteSync();
    } catch (_) {
      // Whatever we did move is safe where it landed; the rest retries next
      // launch.
    }
  }

  void _encryptPlaintextBacklog() {
    final cipher = _cipher;
    if (cipher == null || !dir.existsSync()) return;
    for (final f in _files().where((f) => f.path.endsWith('.json'))) {
      try {
        final id = _idOf(f);
        // Temp-then-rename, same as [enqueueSync]: plaintext is dropped only
        // once the `.enc` is in place, so an interruption leaves a readable
        // duplicate rather than nothing; [pending] resolves that duplicate.
        File('${_dir.path}/$id.tmp')
          ..writeAsBytesSync(cipher.encryptSync(f.readAsStringSync()),
              flush: true)
          ..renameSync(_pathFor(id, encrypted: true));
        f.deleteSync();
      } catch (_) {
        // Leave it in plaintext rather than lose it; the next launch retries.
      }
    }
  }

  /// Deletes `<id>.tmp` files: a rename that never happened. Always
  /// plaintext, even with a cipher attached, so leaving them would
  /// accumulate exactly what encryption is meant to prevent.
  void _deleteOrphanedWrites() {
    if (!dir.existsSync()) return;
    try {
      for (final f in dir.listSync().whereType<File>()) {
        if (f.path.endsWith('.tmp')) _deleteQuietly(f);
      }
    } catch (_) {
      // Nothing here is worth failing a drain over.
    }
  }

  /// Writes [incident] to disk. Safe to call from a crash handler. Returns
  /// false if dropped (too large, or the write failed) — never throws, since
  /// an error in the error handler would replace a useful crash report with
  /// a useless one.
  bool enqueueSync(Incident incident) {
    try {
      final payload = incident.encode();
      // Measured on the plaintext so the cap is the same whether or not the
      // key has arrived; GCM only adds a nonce and a tag.
      if (payload.length > maxBytes) return false;

      if (!dir.existsSync()) dir.createSync(recursive: true);
      _evictSync();

      // Temp name then rename, so a crash mid-write can't leave a truncated
      // file that fails to parse on next launch.
      final cipher = _cipher;
      final tmp = File('${dir.path}/${incident.id}.tmp');
      if (cipher == null) {
        tmp.writeAsStringSync(payload, flush: true);
      } else {
        tmp.writeAsBytesSync(cipher.encryptSync(payload), flush: true);
      }
      tmp.renameSync(_pathFor(incident.id, encrypted: cipher != null));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Checked before reading a file's contents: a file in this directory may
  /// have been planted or corrupted rather than written by [enqueueSync],
  /// and reading it before checking its length would hand an attacker on a
  /// rooted device a memory-exhaustion lever. Slack over [maxBytes] covers
  /// the nonce and tag GCM adds.
  bool _readableSize(File f) {
    try {
      return f.lengthSync() <= maxBytes + 1024;
    } catch (_) {
      return false;
    }
  }

  /// Merges [patch] into an already-queued incident's `context`, off the
  /// crash path — for data (a screenshot) that wasn't ready in time for the
  /// synchronous [enqueueSync] call. A no-op if [id] is gone, or if merging
  /// would push the incident over [maxBytes]: either way the original
  /// incident is left untouched rather than lost.
  void amend(String id, Map<String, dynamic> patch) {
    try {
      final file = _existingFileFor(id);
      if (file == null) return;
      if (!_readableSize(file)) return;
      final encrypted = file.path.endsWith('.enc');
      final cipher = _cipher;
      final payload = encrypted
          ? cipher!.decryptSync(file.readAsBytesSync())
          : file.readAsStringSync();
      final json = jsonDecode(payload) as Map<String, dynamic>;
      final context = (json['context'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      json['context'] = {...context, ...patch};
      final updated = jsonEncode(json);
      if (updated.length > maxBytes) return;

      final willBeEncrypted = cipher != null;
      final tmp = File('${dir.path}/$id.tmp');
      if (willBeEncrypted) {
        tmp.writeAsBytesSync(cipher.encryptSync(updated), flush: true);
      } else {
        tmp.writeAsStringSync(updated, flush: true);
      }
      tmp.renameSync(_pathFor(id, encrypted: willBeEncrypted));
      if (encrypted != willBeEncrypted) _deleteQuietly(file);
    } catch (_) {
      // Best-effort: the incident enqueueSync already wrote stays as-is.
    }
  }

  File? _existingFileFor(String id) {
    final enc = File(_pathFor(id, encrypted: true));
    if (enc.existsSync()) return enc;
    final plain = File(_pathFor(id, encrypted: false));
    if (plain.existsSync()) return plain;
    return null;
  }

  /// Pending incidents, oldest first. Files that cannot be read — corrupt,
  /// truncated, tampered with, or written under a key we no longer have — are
  /// deleted rather than retried forever.
  List<Incident> pending() {
    if (!dir.existsSync()) return const [];
    _deleteOrphanedWrites();
    final cipher = _cipher;
    final out = <Incident>[];
    final reported = <String>{};
    for (final f in _files()) {
      final encrypted = f.path.endsWith('.enc');
      final id = _idOf(f);
      // An interrupted sweep can leave both halves of one incident on disk;
      // `.enc` sorts before `.json`, so a tampered `.enc` is evicted before
      // the plaintext duplicate is considered, rather than taking it down.
      if (reported.contains(id)) {
        _deleteQuietly(f);
        continue;
      }
      // No key yet is not the same as unreadable: leave it for the next
      // drain instead of deleting an incident we simply can't open yet.
      if (encrypted && cipher == null) continue;
      if (!_readableSize(f)) {
        _deleteQuietly(f);
        continue;
      }
      try {
        final payload = encrypted
            ? cipher!.decryptSync(f.readAsBytesSync())
            : f.readAsStringSync();
        out.add(
          Incident.fromJson(jsonDecode(payload) as Map<String, dynamic>),
        );
        reported.add(id);
      } catch (_) {
        _deleteQuietly(f);
      }
    }
    return out;
  }

  /// Clears both forms: an incident queued before the key arrived may still
  /// be sitting there in plaintext.
  void remove(String id) {
    _deleteQuietly(File(_pathFor(id, encrypted: false)));
    _deleteQuietly(File(_pathFor(id, encrypted: true)));
  }

  String _pathFor(String id, {required bool encrypted}) =>
      '${dir.path}/$id${encrypted ? '.enc' : '.json'}';

  String _idOf(File f) => f.uri.pathSegments.last.split('.').first;

  int get length => dir.existsSync() ? _files().length : 0;

  List<File> _files() {
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json') || f.path.endsWith('.enc'))
        .toList();
    // Filename is the time-ordered incident id, so sorting by name avoids a
    // stat() per file on the crash path.
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  void _evictSync() {
    final files = _files();
    final excess = files.length - (maxPending - 1);
    for (var i = 0; i < excess; i++) {
      _deleteQuietly(files[i]);
    }
  }

  void _moveQuietly(File f, String to) {
    try {
      f.renameSync(to);
    } catch (_) {
      // Rename fails across filesystems (temp dir vs. app-support dir).
      // Copy then drop the original — a duplicate beats a lost incident.
      try {
        f.copySync(to);
        f.deleteSync();
      } catch (_) {
        // Leave the original; the non-recursive delete above lets it survive
        // to the next launch.
      }
    }
  }

  void _deleteQuietly(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // Not worth crashing over; it'll be evicted by the cap eventually.
    }
  }
}

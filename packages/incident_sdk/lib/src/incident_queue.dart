import 'dart:convert';
import 'dart:io';

import 'crypto/incident_cipher.dart';
import 'incident.dart';

/// Disk-backed queue of incidents awaiting upload.
///
/// The crash path calls [enqueueSync] and nothing else. No network, no async,
/// no allocation beyond the encoded payload: a crashing app may not survive
/// long enough for a `Future` to complete, and an incident that only exists in
/// memory is an incident you lose.
///
/// Everything else (draining, deleting) runs later, off the crash path.
class IncidentQueue {
  /// Oldest pending incidents are dropped past this count. A crash loop must
  /// not be able to fill a user's storage.
  final int maxPending;

  /// Incidents larger than this are dropped rather than truncated: a partial
  /// stack trace symbolicates to nonsense and wastes a ticket.
  final int maxBytes;

  /// Where incidents live now. Mutable because the queue outlives its first
  /// directory: see [moveTo]. Anything holding this queue therefore keeps
  /// writing to the right place without being handed a new instance.
  Directory get dir => _dir;
  Directory _dir;

  /// Null until secure storage answers. See [attachCipher] for what happens to
  /// incidents captured before then.
  IncidentCipher? _cipher;

  IncidentQueue({
    required Directory dir,
    this.maxPending = 50,
    this.maxBytes = 512 * 1024,
  }) : _dir = dir;

  /// Starts encrypting, and encrypts whatever was queued before the key was
  /// available. Call as soon as [resolveIncidentCipher] completes.
  ///
  /// **Policy for a crash before the key resolves: write plaintext, encrypt as
  /// soon as the key arrives.** The alternative — buffering in memory until
  /// the key arrives — loses the incident outright, because the process that
  /// crashed during startup is usually the process that dies before the
  /// `Future` completes, and a startup crash is exactly the one worth having.
  ///
  /// The trade-off is a plaintext window: an incident captured between this
  /// queue's creation and the key resolving sits unencrypted until this runs —
  /// within the same launch if the app survives, otherwise at the next one.
  /// The window only stays bounded if every directory the SDK has ever written
  /// to is swept. This sweeps [dir] alone; [moveTo] is what keeps that
  /// sufficient, by bringing an abandoned directory's contents here rather
  /// than leaving plaintext behind in it.
  void attachCipher(IncidentCipher cipher) {
    _cipher = cipher;
    _deleteOrphanedWrites();
    _encryptPlaintextBacklog();
  }

  /// Repoints the queue at [destination] and brings everything already queued
  /// with it.
  ///
  /// Startup writes to a temp directory so the crash handler is live before
  /// `path_provider` answers; everything written there is plaintext, because
  /// it predates the key. The queue moves rather than being replaced by a
  /// second instance: a capture, a guarded zone or any other holder of this
  /// object follows the move, where a replacement would leave them writing to
  /// a directory nothing sweeps, caps or uploads.
  ///
  /// Files are moved rather than re-read, so an already-encrypted file is
  /// carried over intact.
  /// The sweep runs on every call, including the ones with nothing to move: a
  /// previous launch can leave plaintext in the destination itself — key
  /// resolution failed, or a write error interrupted the sweep — and this is
  /// the one point in startup guaranteed to be reached whether or not the app
  /// crashed last time.
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
      // Not recursive, deliberately: this succeeds only once the directory is
      // empty, so a file we failed to move is left where it is instead of
      // being deleted along with the directory. It is then picked up the next
      // time the SDK starts and moves out of the same temp directory.
      previous.deleteSync();
    } catch (_) {
      // Whatever we did move is safe where it landed; the rest is retried on
      // the next launch.
    }
  }

  void _encryptPlaintextBacklog() {
    final cipher = _cipher;
    if (cipher == null || !dir.existsSync()) return;
    for (final f in _files().where((f) => f.path.endsWith('.json'))) {
      try {
        final id = _idOf(f);
        // Temp-then-rename, the same discipline [enqueueSync] uses: a
        // half-written `.enc` must never be visible under its real name.
        // The plaintext is dropped only once the `.enc` is in place, so an
        // interruption leaves a readable duplicate rather than nothing;
        // [pending] resolves that duplicate.
        File('${_dir.path}/$id.tmp')
          ..writeAsBytesSync(cipher.encryptSync(f.readAsStringSync()),
              flush: true)
          ..renameSync(_pathFor(id, encrypted: true));
        f.deleteSync();
      } catch (_) {
        // Leave it in plaintext rather than lose it; the next launch retries,
        // and an unreadable file is evicted by [pending] anyway. A `.tmp`
        // left by a failure here is swept by [_deleteOrphanedWrites].
      }
    }
  }

  /// Deletes `<id>.tmp` files: a write whose rename never happened, because
  /// the rename failed or the process died between the two. [enqueueSync]
  /// already returned false for it, so nobody is waiting on it — and it is
  /// plaintext even when a cipher is attached, so leaving it would accumulate
  /// exactly what encryption is meant to prevent. Runs off the crash path.
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

  /// Writes [incident] to disk. Safe to call from a crash handler.
  ///
  /// Returns false if the incident was dropped (too large, or the write
  /// failed). Never throws: an error inside the error handler would replace a
  /// useful crash report with a useless one.
  bool enqueueSync(Incident incident) {
    try {
      final payload = incident.encode();
      // Measured on the plaintext so the cap means the same thing whether or
      // not the key has arrived; GCM only adds a nonce and a tag.
      if (payload.length > maxBytes) return false;

      if (!dir.existsSync()) dir.createSync(recursive: true);
      _evictSync();

      // Write to a temp name first, then rename. A crash mid-write would
      // otherwise leave a truncated file that fails to parse on next launch.
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

  /// Merges [patch] into an already-queued incident's `context`, off the
  /// crash path — for data (a screenshot) that wasn't ready in time for the
  /// synchronous [enqueueSync] call. A no-op if [id] is gone (evicted,
  /// uploaded, never queued) or if merging would push the incident over
  /// [maxBytes]: either way the original, valid incident is left untouched
  /// rather than lost.
  /// The write path caps size; the read path has to cap it again. A file in
  /// this directory may have been planted or corrupted rather than written by
  /// [enqueueSync], and reading it before checking its length would hand an
  /// attacker on a rooted device a memory-exhaustion lever. The slack over
  /// [maxBytes] covers the nonce and tag GCM adds.
  bool _readableSize(File f) {
    try {
      return f.lengthSync() <= maxBytes + 1024;
    } catch (_) {
      return false;
    }
  }

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
      // An interrupted sweep leaves both halves of one incident on disk. The
      // duplicate is dropped only once the other half has actually been read,
      // never merely because a file with that id exists: a tampered or
      // truncated `.enc` is evicted by the catch below, and presuming it
      // authoritative up front would take the readable plaintext with it and
      // lose the incident the queue exists to deliver. `<id>.enc` sorts before
      // `<id>.json`, so the encrypted half is always decided first.
      if (reported.contains(id)) {
        _deleteQuietly(f);
        continue;
      }
      // No key yet is not the same as an unreadable file: leave it for the
      // next drain rather than delete an incident we simply cannot open yet.
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

  /// Called after a confirmed upload. Clears both forms: an incident queued
  /// before the key arrived may still be sitting there in plaintext.
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
    // Filename is the incident id, which is time-ordered; sorting by name
    // avoids a stat() per file on the crash path.
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
      // A temp directory and the app-support directory can sit on different
      // filesystems, where rename is not allowed. Copy, then drop the
      // original — an incident arriving twice beats one lost.
      try {
        f.copySync(to);
        f.deleteSync();
      } catch (_) {
        // Leave the original in place. The directory delete below is
        // non-recursive precisely so this file survives to the next launch.
      }
    }
  }

  void _deleteQuietly(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // A file we cannot delete is not worth crashing over; it will be
      // evicted by the cap eventually.
    }
  }
}

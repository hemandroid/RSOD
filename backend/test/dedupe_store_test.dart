import 'dart:io';

import 'package:incident_backend/src/dedupe_store.dart';
import 'package:test/test.dart';

/// In-memory stand-in for the store file, so most tests don't touch disk.
class FakeDedupeFileSystem implements DedupeFileSystem {
  String? content;
  int writeCalls = 0;
  bool throwOnWrite = false;

  @override
  String? read(String path) => content;

  @override
  void writeAtomic(String path, String contents) {
    writeCalls++;
    if (throwOnWrite) throw StateError('disk full');
    content = contents;
  }
}

void main() {
  group('JsonFileDedupeStore (fake filesystem)', () {
    test('lookup returns null for a fingerprint never seen', () async {
      final store = JsonFileDedupeStore('unused.json', fileSystem: FakeDedupeFileSystem());

      expect(await store.lookup('fp-1'), isNull);
    });

    test('remember then lookup returns the same issue key, persisted once',
        () async {
      final fs = FakeDedupeFileSystem();
      final store = JsonFileDedupeStore('unused.json', fileSystem: fs);

      await store.remember('fp-1', 'SCRUM-1');

      expect(await store.lookup('fp-1'), 'SCRUM-1');
      expect(fs.writeCalls, 1);
    });

    test('a second store reading the same backing content sees the prior '
        'ticket — this is what "survives a restart" means in practice',
        () async {
      final fs = FakeDedupeFileSystem();
      final beforeRestart = JsonFileDedupeStore('unused.json', fileSystem: fs);
      await beforeRestart.remember('fp-1', 'SCRUM-1');

      final afterRestart = JsonFileDedupeStore('unused.json', fileSystem: fs);

      expect(await afterRestart.lookup('fp-1'), 'SCRUM-1');
    });

    test('corrupt JSON degrades to an empty store instead of throwing',
        () async {
      final fs = FakeDedupeFileSystem()..content = '{not valid json';
      final store = JsonFileDedupeStore('unused.json', fileSystem: fs);

      expect(await store.lookup('fp-1'), isNull);
      // Still fully usable after degrading — a duplicate ticket is the
      // worst case, never a dead store.
      await store.remember('fp-1', 'SCRUM-9');
      expect(await store.lookup('fp-1'), 'SCRUM-9');
    });

    test('valid JSON of the wrong shape (e.g. a list) degrades to empty',
        () async {
      final fs = FakeDedupeFileSystem()..content = '[1, 2, 3]';
      final store = JsonFileDedupeStore('unused.json', fileSystem: fs);

      expect(await store.lookup('anything'), isNull);
    });

    test('a write failure does not throw and does not lose the in-memory '
        'entry for the rest of this run', () async {
      final fs = FakeDedupeFileSystem()..throwOnWrite = true;
      final store = JsonFileDedupeStore('unused.json', fileSystem: fs);

      await store.remember('fp-1', 'SCRUM-1');

      expect(await store.lookup('fp-1'), 'SCRUM-1');
    });

    test('caps growth by evicting the oldest fingerprint first', () async {
      final fs = FakeDedupeFileSystem();
      final store = JsonFileDedupeStore('unused.json', fileSystem: fs, capacity: 2);

      await store.remember('fp-1', 'SCRUM-1');
      await store.remember('fp-2', 'SCRUM-2');
      await store.remember('fp-3', 'SCRUM-3');

      expect(await store.lookup('fp-1'), isNull, reason: 'oldest evicted');
      expect(await store.lookup('fp-2'), 'SCRUM-2');
      expect(await store.lookup('fp-3'), 'SCRUM-3');
    });
  });

  group('JsonFileDedupeStore (real filesystem, temp directory)', () {
    late Directory tempDir;
    late String path;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dedupe_store_test');
      path = '${tempDir.path}/dedupe.json';
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('a ticket filed before restart is found after restart', () async {
      final beforeRestart = JsonFileDedupeStore(path);
      await beforeRestart.remember('fp-1', 'SCRUM-1');

      // A fresh instance pointed at the same file, as if the process had
      // just been killed and started again.
      final afterRestart = JsonFileDedupeStore(path);

      expect(await afterRestart.lookup('fp-1'), 'SCRUM-1');
    });

    test('a missing store file starts empty rather than throwing', () async {
      final store = JsonFileDedupeStore('${tempDir.path}/does-not-exist.json');

      expect(await store.lookup('fp-1'), isNull);
    });

    test('a file truncated mid-write (as if killed) degrades to empty',
        () async {
      File(path).writeAsStringSync('{"fp-1": "SCR');
      final store = JsonFileDedupeStore(path);

      expect(await store.lookup('fp-1'), isNull);
    });

    test('a successful write leaves no leftover temp file behind', () async {
      final store = JsonFileDedupeStore(path);

      await store.remember('fp-1', 'SCRUM-1');

      expect(File('$path.tmp').existsSync(), isFalse);
      expect(File(path).existsSync(), isTrue);
    });
  });
}

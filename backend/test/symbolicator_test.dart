import 'dart:typed_data';

import 'package:incident_backend/src/symbolicator.dart';
import 'package:test/test.dart';

/// In-memory stand-in for the real filesystem. Records every path it was
/// asked to read so tests can assert *which* symbols file the picking logic
/// chose, not just the end-to-end outcome.
class FakeSymbolsFileSystem implements SymbolsFileSystem {
  FakeSymbolsFileSystem({
    Map<String, List<String>> dirs = const {},
    Map<String, Uint8List> files = const {},
    this.throwOnList = false,
  })  : _dirs = dirs,
        _files = files;

  final Map<String, List<String>> _dirs;
  final Map<String, Uint8List> _files;
  final bool throwOnList;

  final List<String> listedDirs = [];

  /// Bumped by a test to simulate a rebuild writing new symbols to the same
  /// path — the cache must notice and re-parse.
  int generation = 0;

  @override
  String? stamp(String path) =>
      _files.containsKey(path) ? 'gen-$generation' : null;
  final List<String> readAttempts = [];

  @override
  List<String> listFiles(String dir) {
    listedDirs.add(dir);
    if (throwOnList) throw StateError('boom: directory unreadable');
    return _dirs[dir] ?? const [];
  }

  @override
  Uint8List? readBytes(String path) {
    readAttempts.add(path);
    return _files[path];
  }
}

/// Not real DWARF data — enough to prove `Dwarf.fromBytes` is asked to parse
/// it and fails gracefully, without needing a genuine debug-info fixture.
Uint8List garbageBytes() => Uint8List.fromList('not dwarf data at all'.codeUnits);

/// A minimal but real non-symbolic-trace header, per the exact grammar in
/// native_stack_traces' `_osArchLineRE` (`os=... arch=... comp=... sim=...`).
String traceWithArch(String arch) => [
      '*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***',
      'os=android arch=$arch comp=no sim=no',
      'isolate_instructions=0000000000123000 vm_instructions=0000000000100000',
      '#00 abs 0000000000123456 virt 0000000000000456 '
          '_kDartIsolateSnapshotInstructions+0x456',
    ].join('\n');

void main() {
  group('ReleaseSymbolicator degrades to the input unchanged', () {
    test('when the trace is empty', () async {
      final fs = FakeSymbolsFileSystem();
      final sym = ReleaseSymbolicator('symbols', fileSystem: fs);

      expect(await sym.symbolicate('', 'sha1'), '');
      expect(fs.listedDirs, isEmpty, reason: 'empty trace short-circuits');
    });

    test('when the commit has no symbols subdirectory at all', () async {
      final fs = FakeSymbolsFileSystem(dirs: {});
      final sym = ReleaseSymbolicator('symbols', fileSystem: fs);
      final trace = traceWithArch('arm64');

      expect(await sym.symbolicate(trace, 'unknown-sha'), trace);
    });

    test('when the symbols file is corrupt / not real DWARF data', () async {
      final fs = FakeSymbolsFileSystem(
        dirs: {
          'symbols/sha1': ['app.android-arm64.symbols'],
        },
        files: {
          'symbols/sha1/app.android-arm64.symbols': garbageBytes(),
        },
      );
      final sym = ReleaseSymbolicator('symbols', fileSystem: fs);
      final trace = traceWithArch('arm64');

      expect(await sym.symbolicate(trace, 'sha1'), trace);
    });

    test('when the filesystem seam throws unexpectedly', () async {
      final fs = FakeSymbolsFileSystem(throwOnList: true);
      final sym = ReleaseSymbolicator('symbols', fileSystem: fs);
      final trace = traceWithArch('arm64');

      // Must not throw — an unreadable trace is still worth filing.
      expect(await sym.symbolicate(trace, 'sha1'), trace);
    });
  });

  group('ReleaseSymbolicator picks the right symbols file', () {
    test('matching the trace\'s reported architecture', () async {
      final fs = FakeSymbolsFileSystem(
        dirs: {
          'symbols/sha1': [
            'app.android-arm64.symbols',
            'app.android-x64.symbols',
          ],
        },
        files: {
          'symbols/sha1/app.android-arm64.symbols': garbageBytes(),
          'symbols/sha1/app.android-x64.symbols': garbageBytes(),
        },
      );
      final sym = ReleaseSymbolicator('symbols', fileSystem: fs);

      await sym.symbolicate(traceWithArch('x64'), 'sha1');

      expect(fs.readAttempts, ['symbols/sha1/app.android-x64.symbols']);
    });

    test('falling back to the alphabetically first file when the trace '
        'carries no architecture header', () async {
      final fs = FakeSymbolsFileSystem(
        dirs: {
          'symbols/sha2': ['b.symbols', 'a.symbols'],
        },
        files: {
          'symbols/sha2/a.symbols': garbageBytes(),
          'symbols/sha2/b.symbols': garbageBytes(),
        },
      );
      final sym = ReleaseSymbolicator('symbols', fileSystem: fs);

      await sym.symbolicate('no header lines here\njust plain text', 'sha2');

      expect(fs.readAttempts, ['symbols/sha2/a.symbols']);
    });

    test('caching the parsed result so the same build is not re-read '
        'per incident', () async {
      final fs = FakeSymbolsFileSystem(
        dirs: {
          'symbols/sha3': ['app.symbols'],
        },
        files: {
          'symbols/sha3/app.symbols': garbageBytes(),
        },
      );
      final sym = ReleaseSymbolicator('symbols', fileSystem: fs);

      await sym.symbolicate(traceWithArch('arm64'), 'sha3');
      await sym.symbolicate(traceWithArch('arm64'), 'sha3');
      await sym.symbolicate('a different trace body entirely', 'sha3');

      expect(fs.readAttempts.length, 1,
          reason: 'three incidents from the same build, one file read');
    });

    test('a rebuild at the same commit invalidates the cache', () async {
      // Rebuilding without committing leaves the sha unchanged while the
      // symbols change. A path-only cache would keep serving the previous
      // build's DWARF and emit line numbers that look right and are wrong.
      final fs = FakeSymbolsFileSystem(
        dirs: {
          'symbols/sha4': ['app.symbols'],
        },
        files: {
          'symbols/sha4/app.symbols': garbageBytes(),
        },
      );
      final sym = ReleaseSymbolicator('symbols', fileSystem: fs);

      await sym.symbolicate(traceWithArch('arm64'), 'sha4');
      expect(fs.readAttempts.length, 1);

      fs.generation++; // same path, new contents
      await sym.symbolicate(traceWithArch('arm64'), 'sha4');

      expect(fs.readAttempts.length, 2,
          reason: 'new symbols at the same path must be re-read');
    });

    test('a 64-bit build is preferred over alphabetical order', () async {
      // Sorted alphabetically, 32-bit `arm` comes first. Decoding an arm64
      // trace against it yields plausible nonsense.
      final fs = FakeSymbolsFileSystem(
        dirs: {
          'symbols/sha5': [
            'app.android-arm.symbols',
            'app.android-arm64.symbols',
          ],
        },
        files: {
          'symbols/sha5/app.android-arm.symbols': garbageBytes(),
          'symbols/sha5/app.android-arm64.symbols': garbageBytes(),
        },
      );
      final sym = ReleaseSymbolicator('symbols', fileSystem: fs);

      await sym.symbolicate('a trace with no arch header at all', 'sha5');

      expect(fs.readAttempts.single, contains('arm64'));
    });
  });
}

/// Turns Flutter release stack traces back into file:line, using the DWARF
/// debug info `flutter build ... --split-debug-info` writes for each build.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:native_stack_traces/native_stack_traces.dart';

import 'contracts.dart';

/// A seam so tests can hand in an in-memory fake instead of touching the
/// real filesystem, to exercise "directory missing" and "file corrupt".
abstract class SymbolsFileSystem {
  /// File names directly inside [dir] (no path segments), or empty if [dir]
  /// does not exist, is not a directory, or cannot be listed.
  List<String> listFiles(String dir);

  /// A value that changes whenever the file at [path] changes — its
  /// modification time and length. Null if the file cannot be stat'd.
  String? stamp(String path);

  /// Raw bytes of the file at [path], or null if it is missing or unreadable.
  Uint8List? readBytes(String path);
}

class _IoSymbolsFileSystem implements SymbolsFileSystem {
  const _IoSymbolsFileSystem();

  @override
  List<String> listFiles(String dir) {
    try {
      return [
        for (final entry in Directory(dir).listSync())
          if (entry is File) entry.uri.pathSegments.last,
      ];
    } catch (_) {
      // Missing directory, permissions error, etc. — nothing to symbolicate.
      return const [];
    }
  }

  @override
  String? stamp(String path) {
    try {
      final stat = File(path).statSync();
      return '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
    } catch (_) {
      return null;
    }
  }

  @override
  Uint8List? readBytes(String path) {
    try {
      return File(path).readAsBytesSync();
    } catch (_) {
      return null;
    }
  }
}

/// Decodes obfuscated release stack traces using `native_stack_traces`.
///
/// Layout convention: symbols for commit `<sha>` live at
/// `<symbolsDir>/<sha>/*.symbols`, named however `flutter build
/// --split-debug-info` names them. Keying the directory by the same
/// `--dart-define=COMMIT_SHA` the SDK sends means a rebuild never clobbers a
/// previous build's symbols, and an unmatched commit degrades to "unchanged"
/// rather than decoding against the wrong build's debug info.
class ReleaseSymbolicator implements Symbolicator {
  ReleaseSymbolicator(this._symbolsDir, {SymbolsFileSystem? fileSystem})
      : _fs = fileSystem ?? const _IoSymbolsFileSystem();

  final String _symbolsDir;
  final SymbolsFileSystem _fs;

  /// Keyed by path *and* the file's stamp: rebuilding without committing
  /// leaves the commit sha unchanged while the symbols underneath it change,
  /// and a path-only cache would then serve stale DWARF that produces line
  /// numbers which look right and are wrong.
  final Map<String, Dwarf?> _cache = {};

  @override
  Future<String> symbolicate(String stackTrace, String commitSha) async {
    if (stackTrace.trim().isEmpty) return stackTrace;
    try {
      final lines = const LineSplitter().convert(stackTrace);
      final dwarf = _dwarfFor(commitSha, _archHint(lines));
      if (dwarf == null) return stackTrace;

      // Lines the decoder doesn't recognise as native frames pass through
      // unchanged rather than being corrupted.
      final decoded = await Stream<String>.fromIterable(lines)
          .transform(DwarfStackTraceDecoder(dwarf))
          .toList();
      return decoded.join('\n');
    } catch (_) {
      // Corrupt symbols or an unexpected trace format: still file the
      // incident, just without file:line, rather than lose it entirely.
      return stackTrace;
    }
  }

  /// The trace's own `os=... arch=...` header, when present (emulator
  /// reports `x64`, a real phone `arm64`). Absent or unmatched,
  /// [_pickSymbolsFile] falls back to the first `.symbols` file alphabetically.
  String? _archHint(List<String> lines) {
    try {
      return StackTraceHeader.fromLines(lines).architecture;
    } catch (_) {
      return null;
    }
  }

  Dwarf? _dwarfFor(String commitSha, String? arch) {
    final path = _pickSymbolsFile(commitSha, arch);
    if (path == null) return null;
    final key = '$path@${_fs.stamp(path) ?? 'unstamped'}';
    return _cache.putIfAbsent(key, () {
      final bytes = _fs.readBytes(path);
      if (bytes == null) return null;
      try {
        return Dwarf.fromBytes(bytes);
      } catch (_) {
        return null;
      }
    });
  }

  String? _pickSymbolsFile(String commitSha, String? arch) {
    final dir = '$_symbolsDir/$commitSha';
    final files = _fs
        .listFiles(dir)
        .where((f) => f.endsWith('.symbols'))
        .toList()
      ..sort();
    if (files.isEmpty) return null;

    if (arch != null) {
      // 'x86_64' and 'x64' name the same architecture; normalise before matching.
      const aliases = {'x86_64': 'x64'};
      final needle = aliases[arch] ?? arch;
      for (final f in files) {
        if (f.contains(needle)) return '$dir/$f';
      }
    }
    // Prefer 64-bit: alphabetical order would put 32-bit `arm` first and
    // decode an arm64 trace into nonsense.
    for (final preferred in ['arm64', 'x64']) {
      for (final f in files) {
        if (f.contains(preferred)) return '$dir/$f';
      }
    }
    return '$dir/${files.first}';
  }
}

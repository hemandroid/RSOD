import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:incident_sdk/src/crypto/incident_cipher.dart';
import 'package:incident_sdk/src/incident.dart';
import 'package:incident_sdk/src/incident_queue.dart';

Incident _incident(String id, {String stack = 'stack'}) => Incident(
      id: id,
      capturedAt: DateTime.utc(2026, 9, 19),
      source: IncidentSource.flutterError,
      error: 'boom',
      stackTrace: stack,
      appVersion: '1.0.0',
      commitSha: 'abc123',
      platform: 'android',
    );

void main() {
  late Directory tmp;
  late IncidentQueue queue;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('incident_queue_test');
    queue = IncidentQueue(dir: tmp, maxPending: 3, maxBytes: 1024);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('round-trips an incident through disk', () {
    expect(queue.enqueueSync(_incident('001')), isTrue);

    final pending = queue.pending();
    expect(pending, hasLength(1));
    expect(pending.single.id, '001');
    expect(pending.single.error, 'boom');
    expect(pending.single.commitSha, 'abc123');
  });

  test('drops oldest once maxPending is reached', () {
    for (final id in ['001', '002', '003', '004']) {
      queue.enqueueSync(_incident(id));
    }

    expect(queue.length, 3, reason: 'a crash loop must not fill storage');
    expect(queue.pending().map((i) => i.id), ['002', '003', '004']);
  });

  test('drops oversized incidents instead of truncating', () {
    final huge = _incident('001', stack: 'x' * 2048);

    expect(queue.enqueueSync(huge), isFalse);
    expect(queue.length, 0, reason: 'a partial stack trace is worse than none');
  });

  test('remove deletes only the uploaded incident', () {
    queue.enqueueSync(_incident('001'));
    queue.enqueueSync(_incident('002'));

    queue.remove('001');

    expect(queue.pending().map((i) => i.id), ['002']);
  });

  test('discards corrupt files rather than retrying them forever', () {
    queue.enqueueSync(_incident('001'));
    File('${tmp.path}/002.json').writeAsStringSync('{not json');

    expect(queue.pending().map((i) => i.id), ['001']);
    expect(queue.length, 1, reason: 'the corrupt file should be gone');
  });

  test('never throws from the crash path', () {
    final missing = IncidentQueue(dir: Directory('${tmp.path}/nested/deep'));
    expect(() => missing.enqueueSync(_incident('001')), returnsNormally);
  });

  group('encryption at rest', () {
    IncidentCipher cipher() => IncidentCipher(List<int>.filled(32, 42));

    List<int> diskBytes() => tmp
        .listSync()
        .whereType<File>()
        .expand((f) => f.readAsBytesSync())
        .toList();

    test('round-trips an incident through encrypted storage', () {
      queue.attachCipher(cipher());
      expect(queue.enqueueSync(_incident('001')), isTrue);

      expect(queue.pending().single.id, '001');
      expect(queue.pending().single.error, 'boom');
    });

    test('writes no plaintext field value to disk', () {
      queue.attachCipher(cipher());
      queue.enqueueSync(_incident('001', stack: 'secret-frame'));

      final disk = String.fromCharCodes(diskBytes());
      expect(disk, isNot(contains('secret-frame')));
      expect(disk, isNot(contains('boom')));
      expect(disk, isNot(contains('abc123')));
    });

    test('never writes the key into the incidents directory', () {
      final key = List<int>.filled(32, 42);
      queue.attachCipher(IncidentCipher(key));
      queue.enqueueSync(_incident('001'));

      expect(diskBytes().join(','), isNot(contains(key.join(','))));
    });

    test('evicts a tampered file instead of trusting it', () {
      queue.attachCipher(cipher());
      queue.enqueueSync(_incident('001'));

      final file = tmp.listSync().whereType<File>().single;
      final bytes = file.readAsBytesSync();
      bytes[bytes.length - 1] ^= 0x01; // inside the authentication tag
      file.writeAsBytesSync(bytes, flush: true);

      expect(queue.pending(), isEmpty);
      expect(queue.length, 0, reason: 'a tampered file must not be retried');
    });

    test('keeps a crash captured before the key arrives, then encrypts it', () {
      expect(queue.enqueueSync(_incident('001', stack: 'early-frame')), isTrue,
          reason: 'losing a startup crash is not an acceptable trade');

      queue.attachCipher(cipher());

      expect(String.fromCharCodes(diskBytes()), isNot(contains('early-frame')));
      expect(queue.pending().single.stackTrace, 'early-frame');
    });

    test('leaves encrypted incidents alone until a key is available', () {
      queue.attachCipher(cipher());
      queue.enqueueSync(_incident('001'));

      final coldStart = IncidentQueue(dir: tmp, maxPending: 3, maxBytes: 1024);
      expect(coldStart.pending(), isEmpty);
      expect(coldStart.length, 1, reason: 'the incident is waiting, not lost');

      coldStart.attachCipher(cipher());
      expect(coldStart.pending().single.id, '001');
    });

    test('remove clears an uploaded incident in either form', () {
      queue.enqueueSync(_incident('001'));
      queue.attachCipher(cipher());
      queue.enqueueSync(_incident('002'));

      queue.remove('001');
      queue.remove('002');

      expect(queue.length, 0);
    });

    test('reports an incident once when a sweep was interrupted', () {
      queue.attachCipher(cipher());
      queue.enqueueSync(_incident('001', stack: 'swept'));
      final id = tmp
          .listSync()
          .whereType<File>()
          .single
          .uri
          .pathSegments
          .last
          .split('.')
          .first;
      // The plaintext half an interrupted sweep would leave behind.
      File('${tmp.path}/$id.json')
          .writeAsStringSync(_incident(id, stack: 'swept').encode());

      expect(queue.pending(), hasLength(1),
          reason: 'one incident must not become two tickets');
      expect(queue.length, 1, reason: 'and the plaintext half must be gone');
    });

    test('keeps the plaintext half when the encrypted half is unreadable', () {
      queue.attachCipher(cipher());
      queue.enqueueSync(_incident('001', stack: 'swept'));
      // The plaintext half an interrupted sweep would leave behind.
      File('${tmp.path}/001.json')
          .writeAsStringSync(_incident('001', stack: 'swept').encode());

      final enc = File('${tmp.path}/001.enc');
      final bytes = enc.readAsBytesSync();
      bytes[bytes.length - 1] ^= 0x01; // inside the authentication tag
      enc.writeAsBytesSync(bytes, flush: true);

      expect(queue.pending().single.stackTrace, 'swept',
          reason: 'a tampered .enc must not destroy the readable copy');
      expect(queue.length, 1, reason: 'and the tampered half must be gone');
    });

    test('deletes a write that never completed its rename', () {
      queue.attachCipher(cipher());
      File('${tmp.path}/001.tmp').writeAsStringSync(
        _incident('001', stack: 'half-written').encode(),
      );

      queue.pending();

      expect(tmp.listSync(), isEmpty,
          reason: 'an orphaned .tmp is plaintext nobody is waiting for');
    });

    test('sweeps orphaned writes when the key arrives', () {
      File('${tmp.path}/001.tmp').writeAsStringSync('half-written');

      queue.attachCipher(cipher());

      expect(tmp.listSync(), isEmpty);
    });
  });

  group('moveTo', () {
    late Directory previous;
    IncidentCipher cipher() => IncidentCipher(List<int>.filled(32, 42));

    String diskUnder(Directory d) => String.fromCharCodes(
          d.listSync().whereType<File>().expand((f) => f.readAsBytesSync()),
        );

    setUp(() => previous = Directory.systemTemp.createTempSync('prev_queue'));
    tearDown(() {
      if (previous.existsSync()) previous.deleteSync(recursive: true);
    });

    test('carries the backlog to the new directory and encrypts it', () {
      final queue = IncidentQueue(dir: previous, maxPending: 3);
      queue.enqueueSync(_incident('001', stack: 'startup-frame'));
      queue.attachCipher(cipher());

      queue.moveTo(tmp);

      expect(queue.pending().single.stackTrace, 'startup-frame');
      expect(diskUnder(tmp), isNot(contains('startup-frame')));
    });

    test('encrypts the moved backlog when the key arrives after the move', () {
      final queue = IncidentQueue(dir: previous, maxPending: 3);
      queue.enqueueSync(_incident('001', stack: 'startup-frame'));

      queue.moveTo(tmp);
      queue.attachCipher(cipher());

      expect(diskUnder(tmp), isNot(contains('startup-frame')));
      expect(queue.pending().single.id, '001');
    });

    test('keeps writing to the new directory afterwards', () {
      final queue = IncidentQueue(dir: previous, maxPending: 3);

      queue.moveTo(tmp);
      queue.enqueueSync(_incident('001'));

      expect(previous.existsSync(), isFalse);
      expect(tmp.listSync().whereType<File>(), hasLength(1));
    });

    test('leaves nothing behind in the abandoned directory', () {
      final queue = IncidentQueue(dir: previous, maxPending: 3);
      queue.attachCipher(cipher());
      queue.enqueueSync(_incident('001'));
      File('${previous.path}/002.tmp').writeAsStringSync('half-written');

      queue.moveTo(tmp);

      expect(previous.existsSync(), isFalse,
          reason: 'stranded plaintext is the whole point of the move');
      expect(queue.pending().single.id, '001',
          reason: 'an already-encrypted file must survive the move intact');
    });

    test('never deletes a file it could not move', () {
      final queue = IncidentQueue(dir: previous, maxPending: 3);
      queue.enqueueSync(_incident('001', stack: 'unmovable'));
      final name =
          previous.listSync().whereType<File>().single.uri.pathSegments.last;
      // Occupy the destination path so both the rename and the copy fail.
      Directory('${tmp.path}/$name').createSync(recursive: true);
      File('${tmp.path}/$name/blocker').writeAsStringSync('x');

      queue.moveTo(tmp);

      expect(previous.listSync().whereType<File>(), hasLength(1),
          reason: 'a file we failed to move must survive to the next launch');
      expect(File('${previous.path}/$name').readAsStringSync(),
          contains('unmovable'));
    });

    test('encrypts plaintext left in the destination by a past launch', () {
      // No startup crash this launch, so the temp directory never came into
      // existence and there is nothing to move — but a previous launch left
      // plaintext in the durable directory.
      final queue =
          IncidentQueue(dir: Directory('${previous.path}/never-written'));
      queue.attachCipher(cipher());
      File('${tmp.path}/002.json')
          .writeAsStringSync(_incident('002', stack: 'never-swept').encode());

      queue.moveTo(tmp);

      expect(diskUnder(tmp), isNot(contains('never-swept')),
          reason: 'a launch with nothing to move must still sweep');
      expect(queue.pending().single.stackTrace, 'never-swept');
    });

    test('is a no-op when the destination is the directory in use', () {
      queue.attachCipher(cipher());
      queue.enqueueSync(_incident('001'));

      queue.moveTo(tmp);

      expect(queue.pending().single.id, '001');
      expect(tmp.existsSync(), isTrue);
    });
  });

  group('amend', () {
    test('merges a patch into an already-queued incident\'s context', () {
      queue.enqueueSync(_incident('001'));

      queue.amend('001', {'screenshot': {'format': 'png', 'bytes': 5}});

      final context = queue.pending().single.context;
      expect(context['screenshot'], {'format': 'png', 'bytes': 5});
    });

    test('re-encrypts the amended incident when a cipher is attached', () {
      final cipher = IncidentCipher(List<int>.filled(32, 42));
      queue.attachCipher(cipher);
      queue.enqueueSync(_incident('001'));

      queue.amend('001', {'screenshot': {'format': 'png'}});

      expect(File('${tmp.path}/001.json').existsSync(), isFalse,
          reason: 'no plaintext left behind after amending under a cipher');
      expect(queue.pending().single.context['screenshot'], {'format': 'png'});
    });

    test('is a no-op when the incident is gone', () {
      expect(() => queue.amend('missing', {'screenshot': {}}),
          returnsNormally);
      expect(queue.length, 0);
    });

    test('leaves the original incident untouched if the patch would exceed maxBytes', () {
      queue.enqueueSync(_incident('001'));

      queue.amend('001', {'screenshot': {'image_base64': 'x' * 4096}});

      final pending = queue.pending();
      expect(pending, hasLength(1));
      expect(pending.single.context.containsKey('screenshot'), isFalse);
    });
  });
}

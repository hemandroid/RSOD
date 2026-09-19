import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incident_sdk/src/crypto/incident_cipher.dart';

IncidentCipher _cipher([int fill = 7]) =>
    IncidentCipher(List<int>.filled(32, fill));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const payload = '{"error":"RangeError","user":"ada@example.com"}';

  test('round-trips a payload', () {
    final cipher = _cipher();
    expect(cipher.decryptSync(cipher.encryptSync(payload)), payload);
  });

  test('leaves no plaintext in the encrypted bytes', () {
    final bytes = _cipher().encryptSync(payload);

    expect(utf8.decode(bytes, allowMalformed: true), isNot(contains('ada@')));
    expect(
      utf8.decode(bytes, allowMalformed: true),
      isNot(contains('RangeError')),
    );
  });

  test('uses a fresh nonce so identical payloads differ on disk', () {
    final cipher = _cipher();

    expect(cipher.encryptSync(payload), isNot(cipher.encryptSync(payload)));
  });

  // Layout is nonce(12) || ciphertext || tag(16). Each region is flipped
  // explicitly: authentication has to reject all three, and the failure has
  // to be an authentication failure rather than a decode error that happens
  // to throw.
  final authenticationFailure = throwsA(isA<SecretBoxAuthenticationError>());

  test('rejects a byte flipped in the ciphertext', () {
    final cipher = _cipher();
    final bytes = Uint8List.fromList(cipher.encryptSync(payload));
    bytes[12] ^= 0x01;

    expect(() => cipher.decryptSync(bytes), authenticationFailure);
  });

  test('rejects a byte flipped in the authentication tag', () {
    final cipher = _cipher();
    final bytes = Uint8List.fromList(cipher.encryptSync(payload));
    bytes[bytes.length - 1] ^= 0x01;

    expect(() => cipher.decryptSync(bytes), authenticationFailure);
  });

  test('rejects a byte flipped in the nonce', () {
    final cipher = _cipher();
    final bytes = Uint8List.fromList(cipher.encryptSync(payload));
    bytes[0] ^= 0x01;

    expect(() => cipher.decryptSync(bytes), authenticationFailure);
  });

  test('refuses to decrypt under a different key', () {
    final bytes = _cipher(7).encryptSync(payload);

    expect(() => _cipher(8).decryptSync(bytes), authenticationFailure);
  });

  test('rejects a key that is not 256 bits', () {
    expect(() => IncidentCipher(const []), throwsArgumentError);
    expect(() => IncidentCipher(List<int>.filled(16, 1)), throwsArgumentError);
  });

  group('key resolution', () {
    test('generates and stores a key on first launch', () async {
      final store = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(store);

      final cipher = await resolveIncidentCipher();

      expect(store, hasLength(1),
          reason: 'the data key must live in secure storage');
      expect(base64Decode(store.values.single), hasLength(32));
      expect(cipher.decryptSync(cipher.encryptSync(payload)), payload);
    });

    test('reuses the stored key across launches', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});

      final first = await resolveIncidentCipher();
      final bytes = first.encryptSync(payload);
      final second = await resolveIncidentCipher();

      expect(second.decryptSync(bytes), payload,
          reason: 'a new key each launch would orphan the whole queue');
    });

    test('fails loudly when the stored key is unusable', () async {
      FlutterSecureStorage.setMockInitialValues({
        'incident_sdk.data_key.v1': base64Encode(List<int>.filled(8, 1)),
      });

      await expectLater(resolveIncidentCipher(), throwsArgumentError);
    });
  });
}

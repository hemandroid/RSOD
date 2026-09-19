import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure-storage entry holding the per-install data key. Versioned in the
/// name so a future format change can generate a new key instead of trying to
/// reinterpret the old one.
const _keyEntry = 'incident_sdk.data_key.v1';

/// The pure-Dart implementation, not `AesGcm.with256bits()`: the platform
/// implementations only expose a `Future`, and the crash path cannot await.
final _aes = DartAesGcm.with256bits();

/// AES-GCM over incident payloads, keyed by a random per-install data key.
///
/// GCM rather than CBC because a queued file is attacker-writable on a rooted
/// device: authentication means a tampered file fails loudly instead of
/// decrypting into a plausible-looking incident we would then upload.
class IncidentCipher {
  final SecretKeyData _key;

  IncidentCipher(List<int> keyBytes) : _key = _require256Bits(keyBytes);

  /// Encrypts [payload] with a fresh random nonce. Synchronous because this
  /// runs inside the crash handler.
  ///
  /// The nonce is prepended to the ciphertext and the GCM tag appended, so one
  /// file is one self-describing incident — no sidecar to lose or mismatch.
  Uint8List encryptSync(String payload) => Uint8List.fromList(
        _aes
            .encryptSync(utf8.encode(payload), secretKeyData: _key)
            .concatenation(),
      );

  /// Throws if [bytes] were truncated, tampered with, or written under a
  /// different key. Callers treat that the same way they treat a corrupt
  /// file: delete it, because no retry will ever make it readable.
  String decryptSync(List<int> bytes) => utf8.decode(
        _aes.decryptSync(
          SecretBox.fromConcatenation(
            bytes,
            nonceLength: _aes.nonceLength,
            macLength: _aes.macAlgorithm.macLength,
          ),
          secretKeyData: _key,
        ),
      );

  static SecretKeyData _require256Bits(List<int> bytes) {
    if (bytes.length != _aes.secretKeyLength) {
      throw ArgumentError.value(
        bytes.length,
        'keyBytes',
        'incident_sdk: data key must be ${_aes.secretKeyLength} bytes. '
            'Refusing to encrypt under a key we did not generate.',
      );
    }
    return SecretKeyData(bytes);
  }
}

/// Reads the per-install data key from platform secure storage — Keychain on
/// iOS, the Android keystore-backed store on Android — generating it on first
/// launch. The key never touches the incidents directory, so possessing the
/// queue files is not enough to read them.
///
/// [KeychainAccessibility.first_unlock_this_device] on Apple platforms keeps
/// the key out of iCloud and iTunes backups (a backup of the queue is then
/// undecryptable) while still letting a background crash after reboot-unlock
/// encrypt normally.
///
/// `resetOnError: false` on Android is deliberate: the default wipes the
/// entry on any keystore error and returns null, which reads here as "first
/// launch" and generates a fresh key — orphaning every incident already
/// queued under the old one. A read error must surface as an error, not as a
/// silent re-key.
///
/// Throws if the stored entry is not a 256-bit key: that means something else
/// wrote to our slot, and silently regenerating would quietly discard every
/// queued incident. Fail loudly instead.
Future<IncidentCipher> resolveIncidentCipher({
  FlutterSecureStorage storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  ),
}) async {
  final stored = await storage.read(key: _keyEntry);
  if (stored != null) return IncidentCipher(base64Decode(stored));

  final key = SecretKeyData.random(length: _aes.secretKeyLength).bytes;
  await storage.write(key: _keyEntry, value: base64Encode(key));
  return IncidentCipher(key);
}

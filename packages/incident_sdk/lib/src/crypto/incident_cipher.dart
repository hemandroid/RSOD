import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Versioned so a future key-format change can generate a new key instead of
// reinterpreting the old one.
const _keyEntry = 'incident_sdk.data_key.v1';

// The pure-Dart implementation, not `AesGcm.with256bits()`: the platform
// implementations only expose a `Future`, and the crash path cannot await.
final _aes = DartAesGcm.with256bits();

/// AES-GCM over incident payloads, keyed by a random per-install data key.
/// GCM rather than CBC: a queued file is attacker-writable on a rooted
/// device, so authentication matters — a tampered file must fail loudly
/// rather than decrypt into a plausible incident we'd upload.
class IncidentCipher {
  final SecretKeyData _key;

  IncidentCipher(List<int> keyBytes) : _key = _require256Bits(keyBytes);

  /// Nonce is prepended, GCM tag appended — one file is one self-describing
  /// incident.
  Uint8List encryptSync(String payload) => Uint8List.fromList(
        _aes
            .encryptSync(utf8.encode(payload), secretKeyData: _key)
            .concatenation(),
      );

  /// Throws on a truncated, tampered, or wrong-key file — callers delete
  /// rather than retry.
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

/// Reads the per-install data key from platform secure storage, generating
/// it on first launch. `resetOnError: false` on Android is deliberate: the
/// default wipes the entry on a keystore error and would read as "first
/// launch", silently orphaning every incident queued under the old key.
Future<IncidentCipher> resolveIncidentCipher({
  FlutterSecureStorage storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
    // `first_unlock_this_device` keeps the key out of iCloud/iTunes backups.
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

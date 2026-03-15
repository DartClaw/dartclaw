import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

/// Bidirectional UUID <-> phone mapping for Signal sender normalization.
///
/// Signal's sealed-sender protocol means unknown senders appear as ACI UUID
/// only. When signal-cli later learns the phone, subsequent messages switch
/// identifiers. This map caches the association so UUID-only messages resolve
/// to the stable phone number for consistent session key derivation.
class SignalSenderMap {
  static final _log = Logger('SignalSenderMap');

  static final _e164Pattern = RegExp(r'^\+[1-9]\d{1,14}$');
  static final _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  final String filePath;
  final Map<String, String> _uuidToPhone = {};
  final Map<String, String> _phoneToUuid = {};

  /// Pending write future, chained to serialize file writes.
  Future<void> _pendingWrite = Future.value();

  SignalSenderMap({required this.filePath});

  /// Number of stored mappings.
  int get length => _uuidToPhone.length;

  /// Load mappings from the JSON file. Logs a warning and starts empty on
  /// missing or corrupt files.
  Future<void> load() async {
    final file = File(filePath);
    if (!file.existsSync()) {
      _log.info('No sender map file at $filePath — starting empty');
      return;
    }
    try {
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final mappings = json['mappings'] as Map<String, dynamic>?;
      if (mappings == null) {
        _log.warning('Sender map file missing "mappings" key — starting empty');
        return;
      }
      for (final entry in mappings.entries) {
        final uuid = entry.key;
        final phone = entry.value as String;
        if (_isValidUuid(uuid) && _isValidE164(phone)) {
          _uuidToPhone[uuid.toLowerCase()] = phone;
          _phoneToUuid[phone] = uuid.toLowerCase();
        }
      }
      _log.info('Loaded ${_uuidToPhone.length} sender mappings');
    } catch (e) {
      _log.warning('Failed to load sender map from $filePath — starting empty', e);
    }
  }

  /// Resolve the normalized sender ID from available signal-cli fields.
  ///
  /// - Both phone and UUID present and valid: store mapping, return phone.
  /// - UUID only: return cached phone if mapping exists, else return UUID.
  /// - Phone only: return phone as-is.
  /// - Neither: return empty string.
  String resolve({String? sourceNumber, String? sourceUuid}) {
    final hasPhone = sourceNumber != null && sourceNumber.isNotEmpty;
    final hasUuid = sourceUuid != null && sourceUuid.isNotEmpty;

    if (hasPhone && hasUuid) {
      final validPhone = _isValidE164(sourceNumber);
      final validUuid = _isValidUuid(sourceUuid);
      if (validPhone && validUuid) {
        _storeMapping(sourceUuid.toLowerCase(), sourceNumber);
      }
      return validPhone ? sourceNumber : sourceUuid;
    }

    if (hasUuid && !hasPhone) {
      final cached = _uuidToPhone[sourceUuid.toLowerCase()];
      return cached ?? sourceUuid;
    }

    if (hasPhone) return sourceNumber;

    return '';
  }

  void _storeMapping(String uuid, String phone) {
    final existing = _uuidToPhone[uuid];
    if (existing == phone) return; // No change

    // Remove old reverse entry if phone changed
    if (existing != null) {
      _phoneToUuid.remove(existing);
    }

    _uuidToPhone[uuid] = phone;
    _phoneToUuid[phone] = uuid;
    unawaited(_persist());
  }

  Future<void> _persist() {
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        final json = jsonEncode({'version': 1, 'mappings': _uuidToPhone});
        final file = File(filePath);
        await file.parent.create(recursive: true);
        await file.writeAsString(json);
      } catch (e) {
        _log.warning('Failed to persist sender map', e);
      }
    });
    return _pendingWrite;
  }

  static bool _isValidE164(String value) => _e164Pattern.hasMatch(value);
  static bool _isValidUuid(String value) => _uuidPattern.hasMatch(value);
}

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';

const _ttl = Duration(days: 7);
const _pendingTimeout = Duration(minutes: 15);
const _purgeInterval = Duration(hours: 1);
const _statePending = 'pending';
const _stateProcessed = 'processed';

/// Result of trying to reserve a webhook delivery for processing.
enum WebhookDeliveryReservation {
  /// The delivery has not been seen before and is now pending.
  reservedNew,

  /// A stale pending delivery was reclaimed for retry.
  reservedReclaimed,

  /// The delivery is already processed or actively pending.
  duplicate,
}

/// Opens a file-backed [WebhookDeliveryStore] in [path].
WebhookDeliveryStore openWebhookDeliveryStore(String path, {DateTime Function()? now}) {
  final directory = Directory(path)..createSync(recursive: true);
  _sweepTempFiles(directory);
  return WebhookDeliveryStore(directory, now: now);
}

/// File-backed idempotency store for GitHub webhook delivery IDs.
class WebhookDeliveryStore {
  new(this.directory, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Directory directory;
  final DateTime Function() _now;
  DateTime? _lastPurgeAt;

  /// Reserves [deliveryId] for processing.
  WebhookDeliveryReservation reservePending(String deliveryId, {Duration stalePendingAfter = _pendingTimeout}) {
    final now = _now().toUtc();
    _purgeIfDue(now);
    final marker = _marker(deliveryId);
    try {
      marker.createSync(exclusive: true);
      _writeClaimed(marker, _body(_statePending, now));
      return WebhookDeliveryReservation.reservedNew;
    } on FileSystemException {
      if (!marker.existsSync()) rethrow;
    }

    final body = _readBody(marker);
    if (body?['state'] == _stateProcessed) return WebhookDeliveryReservation.duplicate;
    final updatedAt = DateTime.tryParse(body?['updated_at'] as String? ?? '');
    if (updatedAt != null && updatedAt.isAfter(now.subtract(stalePendingAfter))) {
      return WebhookDeliveryReservation.duplicate;
    }
    secureWriteFileSync(marker, jsonEncode(_body(_statePending, now)), restrictPermissions: false);
    return WebhookDeliveryReservation.reservedReclaimed;
  }

  /// Marks [deliveryId] as processed after workflow start succeeds.
  void commitProcessed(String deliveryId) {
    final now = _now().toUtc();
    final marker = _marker(deliveryId);
    final contents = _body(_stateProcessed, now);
    if (!marker.existsSync()) {
      try {
        marker.createSync(exclusive: true);
        _writeClaimed(marker, contents);
        return;
      } on FileSystemException {
        if (!marker.existsSync()) rethrow;
      }
    }
    secureWriteFileSync(marker, jsonEncode(contents), restrictPermissions: false);
  }

  /// Releases a pending [deliveryId] after workflow start fails.
  void releasePending(String deliveryId) {
    final marker = _marker(deliveryId);
    if (!marker.existsSync()) return;
    final body = _readBody(marker);
    if (body?['state'] == _stateProcessed) return;
    marker.deleteSync();
  }

  File _marker(String deliveryId) => File(p.join(directory.path, sha256.convert(utf8.encode(deliveryId)).toString()));

  void _purgeIfDue(DateTime now) {
    final lastPurgeAt = _lastPurgeAt;
    if (lastPurgeAt != null && now.difference(lastPurgeAt) < _purgeInterval) return;
    _lastPurgeAt = now;
    final cutoff = now.subtract(_ttl);
    for (final entity in directory.listSync()) {
      if (entity is! File || entity.path.endsWith('.tmp')) continue;
      final body = _readBody(entity);
      if (body?['state'] != _stateProcessed) continue;
      final insertedAt = DateTime.tryParse(body?['inserted_at'] as String? ?? '');
      if (insertedAt == null || !insertedAt.isBefore(cutoff)) continue;
      try {
        entity.deleteSync();
      } on FileSystemException {
        // A marker held by another process remains eligible for a later purge.
      }
    }
  }
}

Map<String, String> _body(String state, DateTime now) {
  final timestamp = now.toIso8601String();
  return {'state': state, 'inserted_at': timestamp, 'updated_at': timestamp};
}

Map<String, dynamic>? _readBody(File marker) {
  try {
    final decoded = jsonDecode(marker.readAsStringSync());
    if (decoded is! Map<String, dynamic>) return null;
    return decoded;
  } on Object {
    return null;
  }
}

void _writeClaimed(File marker, Map<String, String> body) {
  final handle = marker.openSync(mode: FileMode.writeOnly);
  try {
    handle.writeStringSync(jsonEncode(body));
    handle.flushSync();
  } finally {
    handle.closeSync();
  }
}

void _sweepTempFiles(Directory directory) {
  for (final entity in directory.listSync()) {
    if (entity is File && entity.path.endsWith('.tmp')) {
      try {
        entity.deleteSync();
      } on FileSystemException {
        // A concurrently held temp file is harmless and will be retried next open.
      }
    }
  }
}

import 'package:sqlite3/sqlite3.dart';

/// How long a seen delivery ID is retained before TTL purge.
const _ttlDays = 7;
const _pendingTimeout = Duration(minutes: 15);
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

/// Opens a file-backed [WebhookDeliveryStore] at [path].
WebhookDeliveryStore openWebhookDeliveryStore(String path) => WebhookDeliveryStore(sqlite3.open(path));

/// Opens an in-memory [WebhookDeliveryStore] (for tests).
WebhookDeliveryStore openWebhookDeliveryStoreInMemory() => WebhookDeliveryStore(sqlite3.openInMemory());

/// SQLite-backed idempotency store for GitHub webhook delivery IDs.
///
/// Delivery IDs move from pending to processed after the workflow start accepts
/// the request. Existing two-column rows migrate as processed so previously
/// handled deliveries remain deduped.
class WebhookDeliveryStore {
  final Database _db;

  /// Creates a store backed by [db] and initializes the required schema.
  WebhookDeliveryStore(this._db) {
    _initSchema();
  }

  void _initSchema() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS webhook_delivery_ids (
        delivery_id TEXT PRIMARY KEY,
        inserted_at TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'processed',
        updated_at TEXT NOT NULL
      )
    ''');
    final columns = _columnNames();
    if (!columns.contains('state')) {
      _db.execute("ALTER TABLE webhook_delivery_ids ADD COLUMN state TEXT NOT NULL DEFAULT 'processed'");
    }
    if (!columns.contains('updated_at')) {
      _db.execute('ALTER TABLE webhook_delivery_ids ADD COLUMN updated_at TEXT');
      _db.execute('UPDATE webhook_delivery_ids SET updated_at = inserted_at WHERE updated_at IS NULL');
    }
  }

  /// Returns `true` and records [deliveryId] if it has not been seen before.
  /// Returns `false` without writing if [deliveryId] is already present.
  ///
  /// Stale entries older than [_ttlDays] days are purged on each call.
  bool registerIfNew(String deliveryId) {
    if (reservePending(deliveryId) == WebhookDeliveryReservation.duplicate) return false;
    commitProcessed(deliveryId);
    return true;
  }

  /// Reserves [deliveryId] for processing.
  ///
  /// Returns whether [deliveryId] was newly reserved, reclaimed, or duplicated.
  WebhookDeliveryReservation reservePending(String deliveryId, {Duration stalePendingAfter = _pendingTimeout}) {
    final now = DateTime.now().toUtc();
    _purgeStaleBefore(now.subtract(const Duration(days: _ttlDays)));
    _db.execute('BEGIN IMMEDIATE');
    try {
      final row = _deliveryRow(deliveryId);
      if (row == null) {
        _insert(deliveryId, state: _statePending, now: now);
        _db.execute('COMMIT');
        return WebhookDeliveryReservation.reservedNew;
      }

      final state = row['state'] as String;
      if (state == _stateProcessed) {
        _db.execute('COMMIT');
        return WebhookDeliveryReservation.duplicate;
      }

      final updatedAt = DateTime.tryParse(row['updated_at'] as String? ?? row['inserted_at'] as String);
      final isStale = updatedAt == null || !updatedAt.isAfter(now.subtract(stalePendingAfter));
      if (!isStale) {
        _db.execute('COMMIT');
        return WebhookDeliveryReservation.duplicate;
      }

      _updateState(deliveryId, state: _statePending, now: now);
      _db.execute('COMMIT');
      return WebhookDeliveryReservation.reservedReclaimed;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Marks [deliveryId] as processed after workflow start succeeds.
  void commitProcessed(String deliveryId) {
    final now = DateTime.now().toUtc();
    final stmt = _db.prepare('''
      INSERT INTO webhook_delivery_ids (delivery_id, inserted_at, state, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(delivery_id) DO UPDATE SET
        inserted_at = excluded.inserted_at,
        state = excluded.state,
        updated_at = excluded.updated_at
    ''');
    try {
      stmt.execute([deliveryId, now.toIso8601String(), _stateProcessed, now.toIso8601String()]);
    } finally {
      stmt.close();
    }
  }

  /// Releases a pending [deliveryId] after workflow start fails.
  void releasePending(String deliveryId) {
    final stmt = _db.prepare('DELETE FROM webhook_delivery_ids WHERE delivery_id = ? AND state = ?');
    try {
      stmt.execute([deliveryId, _statePending]);
    } finally {
      stmt.close();
    }
  }

  Set<String> _columnNames() {
    final rows = _db.select('PRAGMA table_info(webhook_delivery_ids)');
    return rows.map((row) => row['name'] as String).toSet();
  }

  Row? _deliveryRow(String deliveryId) {
    final stmt = _db.prepare('''
      SELECT delivery_id, inserted_at, state, updated_at
      FROM webhook_delivery_ids
      WHERE delivery_id = ?
    ''');
    try {
      final result = stmt.select([deliveryId]);
      return result.isEmpty ? null : result.first;
    } finally {
      stmt.close();
    }
  }

  void _insert(String deliveryId, {required String state, required DateTime now}) {
    final stmt = _db.prepare('''
      INSERT INTO webhook_delivery_ids (delivery_id, inserted_at, state, updated_at)
      VALUES (?, ?, ?, ?)
    ''');
    try {
      stmt.execute([deliveryId, now.toIso8601String(), state, now.toIso8601String()]);
    } finally {
      stmt.close();
    }
  }

  void _updateState(String deliveryId, {required String state, required DateTime now}) {
    final stmt = _db.prepare('''
      UPDATE webhook_delivery_ids
      SET state = ?, updated_at = ?
      WHERE delivery_id = ?
    ''');
    try {
      stmt.execute([state, now.toIso8601String(), deliveryId]);
    } finally {
      stmt.close();
    }
  }

  void _purgeStaleBefore(DateTime cutoff) {
    final stmt = _db.prepare('DELETE FROM webhook_delivery_ids WHERE state = ? AND inserted_at < ?');
    try {
      stmt.execute([_stateProcessed, cutoff.toIso8601String()]);
    } finally {
      stmt.close();
    }
  }
}

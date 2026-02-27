import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import 'atomic_write.dart';
import 'uuid_validation.dart';

class SessionService {
  final String baseDir;
  static const _uuid = Uuid();

  SessionService({required this.baseDir});

  Future<Session> createSession({SessionType type = SessionType.user, String? channelKey}) async {
    final id = _uuid.v4();
    final dir = Directory(p.join(baseDir, id));
    await dir.create(recursive: true);

    final now = DateTime.now();
    final session = Session(id: id, type: type, channelKey: channelKey, createdAt: now, updatedAt: now);
    await atomicWriteJson(File(p.join(dir.path, 'meta.json')), session.toJson());
    return session;
  }

  /// Ensures exactly one main session exists. Returns it.
  Future<Session> getOrCreateMain() async {
    return getOrCreateByKey('main', type: SessionType.main);
  }

  Future<Session?> getSession(String id) async {
    if (!isValidUuid(id)) return null;
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return null;
    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    return Session.fromJson(json);
  }

  Future<List<Session>> listSessions({SessionType? type, List<SessionType>? types}) async {
    final dir = Directory(baseDir);
    if (!dir.existsSync()) return [];

    final sessions = <Session>[];
    await for (final entity in dir.list()) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (!isValidUuid(name)) continue;
      final metaFile = File(p.join(entity.path, 'meta.json'));
      if (!metaFile.existsSync()) continue;
      try {
        final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
        final session = Session.fromJson(json);
        if (type != null && session.type != type) continue;
        if (types != null && !types.contains(session.type)) continue;
        sessions.add(session);
      } catch (_) {
        // Skip malformed session dirs
      }
    }
    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sessions;
  }

  Future<int> updateTitle(String id, String title) async {
    if (!isValidUuid(id)) return 0;
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return 0;

    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    final session = Session.fromJson(json);
    final updated = session.copyWith(title: title, updatedAt: DateTime.now());
    await atomicWriteJson(metaFile, updated.toJson());
    return 1;
  }

  Future<void> touchUpdatedAt(String id) async {
    if (!isValidUuid(id)) return;
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return;

    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    final session = Session.fromJson(json);
    final updated = session.copyWith(updatedAt: DateTime.now());
    await atomicWriteJson(metaFile, updated.toJson());
  }

  /// Creates or retrieves a session by deterministic external key.
  /// Maps external keys (e.g. 'cron:daily-summary') to internal UUID sessions
  /// via a key->UUID index file.
  Future<Session> getOrCreateByKey(String key, {SessionType type = SessionType.user}) async {
    final indexFile = File(p.join(baseDir, '.session_keys.json'));

    // Load existing index
    Map<String, String> keyIndex = {};
    if (indexFile.existsSync()) {
      try {
        final raw = jsonDecode(await indexFile.readAsString());
        if (raw is Map) keyIndex = Map<String, String>.from(raw);
      } catch (_) {}
    }

    // Check if key already maps to a session
    final existingId = keyIndex[key];
    if (existingId != null) {
      final session = await getSession(existingId);
      if (session != null && session.type != SessionType.archive) {
        // Lazy migration: update type/channelKey if needed (e.g. old sessions without type)
        if (session.type != type || session.channelKey != key) {
          final migrated = session.copyWith(type: type, channelKey: key);
          await _updateSession(migrated);
          return migrated;
        }
        return session;
      }
      // Stale/archived mapping — remove and create new
      keyIndex.remove(key);
    }

    // Create new session and record mapping
    final session = await createSession(type: type, channelKey: key);
    keyIndex[key] = session.id;
    await atomicWriteJson(indexFile, keyIndex);
    return session;
  }

  /// Updates session type (e.g. archive→user for resume).
  Future<Session?> updateSessionType(String id, SessionType type) async {
    if (!isValidUuid(id)) return null;
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return null;

    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    final session = Session.fromJson(json);
    final updated = session.copyWith(type: type, updatedAt: DateTime.now());
    await atomicWriteJson(metaFile, updated.toJson());
    return updated;
  }

  /// Types that cannot be deleted (system-managed sessions).
  static const _protectedTypes = {SessionType.main, SessionType.channel, SessionType.cron};

  Future<int> deleteSession(String id) async {
    if (!isValidUuid(id)) return 0;
    final metaFile = File(p.join(baseDir, id, 'meta.json'));
    if (!metaFile.existsSync()) return 0;
    try {
      final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      final session = Session.fromJson(json);
      if (_protectedTypes.contains(session.type)) {
        throw StateError('Cannot delete ${session.type.name} session');
      }
    } catch (e) {
      if (e is StateError) rethrow;
      // Malformed meta — allow delete
    }
    final dir = Directory(p.join(baseDir, id));
    await dir.delete(recursive: true);
    return 1;
  }

  /// Writes updated session metadata to disk.
  Future<void> _updateSession(Session session) async {
    final metaFile = File(p.join(baseDir, session.id, 'meta.json'));
    await atomicWriteJson(metaFile, session.toJson());
  }
}

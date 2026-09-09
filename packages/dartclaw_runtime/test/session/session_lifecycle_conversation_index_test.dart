import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/maintenance/session_maintenance_service.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_runtime/src/session/session_reset_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dataDir;
  late DartclawConfig config;
  late StorageWiring storage;
  late SessionResetService reset;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('conversation_lifecycle_');
    config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    storage = StorageWiring(
      config: config,
      eventBus: EventBus(),
      searchBackendFactory: SqliteBackend.open,
      taskBackendFactory: (_) async => SqliteBackend.openInMemory(),
      exitFn: (code) => throw StateError('unexpected exit $code'),
    );
    await storage.wire();
    reset = SessionResetService(sessions: storage.sessions, messages: storage.messages, resetHour: -1);
  });

  tearDown(() async {
    reset.dispose();
    await storage.messages.dispose();
    await storage.dispose();
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  test('real reset and maintenance transitions remove and restore conversation rows', () async {
    final channelKey = SessionKey.dmShared();
    final channel = await storage.sessions.getOrCreateByKey(channelKey, type: SessionType.channel);
    final channelMessage = await storage.messages.insertMessage(
      sessionId: channel.id,
      role: 'assistant',
      content: 'lifecycleneedle channel retained',
    );
    final channelFile = File(p.join(config.sessionsDir, channel.id, 'messages.ndjson'));
    final channelBytes = channelFile.readAsBytesSync();
    final unkeyed = await storage.sessions.createSession();
    final cleared = await storage.messages.insertMessage(
      sessionId: unkeyed.id,
      role: 'user',
      content: 'lifecycleneedle clear removed',
    );
    final stale = await storage.sessions.createSession();
    final staleMessage = await storage.messages.insertMessage(
      sessionId: stale.id,
      role: 'assistant',
      content: 'lifecycleneedle maintenance retained',
    );
    final staleFile = File(p.join(config.sessionsDir, stale.id, 'messages.ndjson'));
    final staleBytes = staleFile.readAsBytesSync();
    await _expectIds(storage, 'lifecycleneedle', {channelMessage.id, cleared.id, staleMessage.id});

    await reset.resetSession(channel.id, resetContinuity: false);

    await _expectIds(storage, 'lifecycleneedle', {cleared.id, staleMessage.id});
    expect(channelFile.readAsBytesSync(), channelBytes);
    final replacement = await storage.sessions.getByKey(channelKey);
    expect(replacement, isNotNull);
    expect(replacement!.id, isNot(channel.id));

    await reset.resetSession(unkeyed.id, resetContinuity: false);

    await _expectIds(storage, 'lifecycleneedle', {staleMessage.id});
    expect(await storage.messages.getMessages(unkeyed.id), isEmpty);

    _ageSession(config.sessionsDir, stale.id);
    final maintenance = SessionMaintenanceService(
      sessions: storage.sessions,
      config: const SessionMaintenanceConfig(
        mode: MaintenanceMode.enforce,
        pruneAfterDays: 30,
        maxSessions: 0,
        maxDiskMb: 0,
        cronRetentionHours: 0,
      ),
      activeChannelKeys: const {},
      activeJobIds: const {},
      sessionsDir: config.sessionsDir,
    );

    final report = await maintenance.run();

    expect(report.sessionsArchived, 1);
    await _expectIds(storage, 'lifecycleneedle', const {});
    expect(staleFile.readAsBytesSync(), staleBytes);

    await storage.sessions.updateSessionType(stale.id, SessionType.user);

    await _expectIds(storage, 'lifecycleneedle', {staleMessage.id});
  });
}

void _ageSession(String sessionsDir, String sessionId) {
  final file = File(p.join(sessionsDir, sessionId, 'meta.json'));
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  json['updatedAt'] = DateTime.utc(2025).toIso8601String();
  file.writeAsStringSync(jsonEncode(json));
}

Future<void> _expectIds(StorageWiring storage, String query, Set<String> expected) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final actual = (await storage.conversationSearch.search(query)).map((hit) => hit.messageId).toSet();
    if (actual.length == expected.length && actual.containsAll(expected)) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final actual = (await storage.conversationSearch.search(query)).map((hit) => hit.messageId).toSet();
  expect(actual, expected);
}

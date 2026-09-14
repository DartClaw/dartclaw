import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  test('isChatFacing classifies every session type', () {
    expect(
      {for (final type in SessionType.values) type: type.isChatFacing},
      {
        SessionType.main: true,
        SessionType.channel: true,
        SessionType.cron: false,
        SessionType.user: true,
        SessionType.task: false,
        SessionType.logicalAgent: false,
        SessionType.archive: false,
      },
    );
  });

  test('execution routing round-trips and can be cleared explicitly', () {
    final createdAt = DateTime.utc(2026, 8, 9, 10);
    final session = Session(
      id: 'session-1',
      type: SessionType.logicalAgent,
      channelKey: 'agent:search:logical:session-1',
      provider: 'codex',
      securityProfile: 'restricted',
      executionMode: ExecutionMode.container,
      createdAt: createdAt,
      updatedAt: createdAt,
    );

    final decoded = Session.fromJson(session.toJson());
    expect(decoded.provider, 'codex');
    expect(decoded.securityProfile, 'restricted');
    expect(decoded.executionMode, ExecutionMode.container);
    expect(decoded.copyWith(provider: null, securityProfile: null).toJson(), isNot(contains('provider')));
    expect(decoded.copyWith(provider: null, securityProfile: null).toJson(), isNot(contains('securityProfile')));
    expect(decoded.copyWith(executionMode: null).toJson(), isNot(contains('executionMode')));
  });

  test('pinned execution mode is optional for pre-upgrade sessions but never silently coerced', () {
    final json = {'id': 'session-1', 'createdAt': '2026-08-09T10:00:00.000Z', 'updatedAt': '2026-08-09T10:00:00.000Z'};

    expect(Session.fromJson(json).executionMode, isNull, reason: 'a missing mode is derived on load, not rejected');
    expect(Session.fromJson({...json, 'executionMode': 'host'}).executionMode, ExecutionMode.host);
    expect(() => Session.fromJson({...json, 'executionMode': 'vm'}), throwsFormatException);
  });

  test('session type accepts supported names and legacy absence but rejects malformed values', () {
    final json = {'id': 'session-1', 'createdAt': '2026-08-09T10:00:00.000Z', 'updatedAt': '2026-08-09T10:00:00.000Z'};

    expect(Session.fromJson(json).type, SessionType.user);
    for (final type in SessionType.values) {
      expect(Session.fromJson({...json, 'type': type.name}).type, type);
    }
    expect(() => Session.fromJson({...json, 'type': 'future-system'}), throwsFormatException);
    expect(() => Session.fromJson({...json, 'type': 1}), throwsFormatException);
  });

  test('workspace ownership round-trips as an exact pinned pair', () {
    final timestamp = DateTime.utc(2026, 9, 14);
    const workspace = AgentWorkspace(agentId: 'researcher', directory: '/srv/agents/researcher');
    final session = Session(id: 'session-1', workspace: workspace, createdAt: timestamp, updatedAt: timestamp);

    expect(session.toJson(), containsPair('workspaceAgentId', 'researcher'));
    expect(session.toJson(), containsPair('workspaceDir', '/srv/agents/researcher'));
    expect(Session.fromJson(session.toJson()).workspace, workspace);
    expect(Session.fromJson(session.toJson()).workspace?.storagePrincipal, 'agent:researcher');
  });

  test('legacy workspace absence stays absent and partial ownership is malformed', () {
    final json = {'id': 'session-1', 'createdAt': '2026-09-14T00:00:00.000Z', 'updatedAt': '2026-09-14T00:00:00.000Z'};

    expect(Session.fromJson(json).workspace, isNull);
    expect(() => Session.fromJson({...json, 'workspaceAgentId': 'researcher'}), throwsFormatException);
    expect(() => Session.fromJson({...json, 'workspaceDir': '/srv/agents/researcher'}), throwsFormatException);
  });

  test('title race metadata round-trips while legacy records keep neutral defaults', () {
    final json = {'id': 'session-1', 'createdAt': '2026-09-14T00:00:00.000Z', 'updatedAt': '2026-09-14T00:00:00.000Z'};
    final legacy = Session.fromJson(json);
    expect(legacy.titleRevision, 0);
    expect(legacy.titleProvenance, isNull);
    expect(legacy.automaticTitleAttempted, isFalse);

    final titled = legacy.copyWith(
      title: 'Generated title',
      titleRevision: 2,
      titleProvenance: SessionTitleProvenance.automaticGenerated,
      automaticTitleAttempted: true,
    );
    final decoded = Session.fromJson(titled.toJson());
    expect(decoded.titleRevision, 2);
    expect(decoded.titleProvenance, SessionTitleProvenance.automaticGenerated);
    expect(decoded.automaticTitleAttempted, isTrue);
  });
}

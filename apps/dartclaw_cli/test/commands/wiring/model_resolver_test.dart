import 'package:dartclaw_cli/src/commands/wiring/model_resolver.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('resolveChannelTurnOverrides', () {
    test('per-channel override wins over scope and crowd coding defaults', () {
      final config = DartclawConfig(
        sessions: SessionConfig(
          scopeConfig: SessionScopeConfig(
            dmScope: DmScope.perChannelContact,
            groupScope: GroupScope.shared,
            model: 'sonnet',
            effort: 'medium',
            channels: {'google_chat': const ChannelScopeConfig(model: 'opus', effort: 'high')},
          ),
        ),
        governance: const GovernanceConfig(
          crowdCoding: CrowdCodingConfig(model: 'haiku', effort: 'low'),
        ),
      );

      final overrides = resolveChannelTurnOverrides(
        sessionKey: SessionKey.groupShared(channelType: 'google_chat', groupId: 'spaces/AAA'),
        config: config,
      );

      expect(overrides.model, 'opus');
      expect(overrides.effort, 'high');
    });

    test('scope-level override applies when channel type is unavailable', () {
      final config = DartclawConfig(
        sessions: const SessionConfig(
          scopeConfig: SessionScopeConfig(
            dmScope: DmScope.perContact,
            groupScope: GroupScope.shared,
            model: 'sonnet',
            effort: 'medium',
          ),
        ),
        governance: const GovernanceConfig(
          crowdCoding: CrowdCodingConfig(model: 'haiku', effort: 'low'),
        ),
      );

      final overrides = resolveChannelTurnOverrides(
        sessionKey: SessionKey.dmPerContact(peerId: 'alice@example.com'),
        config: config,
      );

      expect(overrides.model, 'sonnet');
      expect(overrides.effort, 'medium');
    });

    test('crowd coding default applies when no scope override exists', () {
      final config = DartclawConfig(
        sessions: const SessionConfig(scopeConfig: SessionScopeConfig.defaults()),
        governance: const GovernanceConfig(
          crowdCoding: CrowdCodingConfig(model: 'haiku', effort: 'low'),
        ),
      );

      final overrides = resolveChannelTurnOverrides(
        sessionKey: SessionKey.groupShared(channelType: 'whatsapp', groupId: 'group@g.us'),
        config: config,
      );

      expect(overrides.model, 'haiku');
      expect(overrides.effort, 'low');
    });

    test('returns null overrides when no model settings are configured', () {
      const config = DartclawConfig.defaults();

      final overrides = resolveChannelTurnOverrides(
        sessionKey: SessionKey.groupShared(channelType: 'signal', groupId: 'group'),
        config: config,
      );

      expect(overrides.model, isNull);
      expect(overrides.effort, isNull);
    });

    test('crowd coding defaults do not apply to DM sessions', () {
      final config = DartclawConfig(
        sessions: const SessionConfig(scopeConfig: SessionScopeConfig.defaults()),
        governance: const GovernanceConfig(
          crowdCoding: CrowdCodingConfig(model: 'haiku', effort: 'low'),
        ),
      );

      final overrides = resolveChannelTurnOverrides(
        sessionKey: SessionKey.dmPerChannelContact(channelType: 'signal', peerId: '+123'),
        config: config,
      );

      expect(overrides.model, isNull);
      expect(overrides.effort, isNull);
    });

    test('non-channel sessions do not receive channel turn overrides', () {
      final config = DartclawConfig(
        sessions: const SessionConfig(scopeConfig: SessionScopeConfig.defaults()),
        governance: const GovernanceConfig(
          crowdCoding: CrowdCodingConfig(model: 'haiku', effort: 'low'),
        ),
      );

      final overrides = resolveChannelTurnOverrides(
        sessionKey: SessionKey.cronSession(jobId: 'daily-review'),
        config: config,
      );

      expect(overrides.model, isNull);
      expect(overrides.effort, isNull);
    });
  });

  group('resolveChannelTurnOverrides with GroupConfigResolver', () {
    GroupConfigResolver resolverWith(ChannelType type, GroupEntry entry) =>
        GroupConfigResolver.fromChannelEntries({
          type: [entry],
        });

    test('per-group model+effort override wins over per-channel and crowd-coding', () {
      final config = DartclawConfig(
        sessions: SessionConfig(
          scopeConfig: SessionScopeConfig(
            dmScope: DmScope.perChannelContact,
            groupScope: GroupScope.shared,
            channels: {'whatsapp': const ChannelScopeConfig(model: 'opus', effort: 'high')},
          ),
        ),
        governance: const GovernanceConfig(
          crowdCoding: CrowdCodingConfig(model: 'sonnet', effort: 'medium'),
        ),
      );
      final resolver = resolverWith(
        ChannelType.whatsapp,
        GroupEntry(id: 'group@g.us', model: 'haiku', effort: 'low'),
      );

      final overrides = resolveChannelTurnOverrides(
        sessionKey: SessionKey.groupShared(channelType: 'whatsapp', groupId: 'group@g.us'),
        config: config,
        groupConfigResolver: resolver,
      );

      expect(overrides.model, 'haiku');
      expect(overrides.effort, 'low');
    });

    test('per-group effort-only override, model falls through to per-channel', () {
      final config = DartclawConfig(
        sessions: SessionConfig(
          scopeConfig: SessionScopeConfig(
            dmScope: DmScope.perChannelContact,
            groupScope: GroupScope.shared,
            channels: {'whatsapp': const ChannelScopeConfig(model: 'opus')},
          ),
        ),
      );
      final resolver = resolverWith(
        ChannelType.whatsapp,
        GroupEntry(id: 'group@g.us', effort: 'high'),
      );

      final overrides = resolveChannelTurnOverrides(
        sessionKey: SessionKey.groupShared(channelType: 'whatsapp', groupId: 'group@g.us'),
        config: config,
        groupConfigResolver: resolver,
      );

      expect(overrides.model, 'opus');
      expect(overrides.effort, 'high');
    });

    test('no per-group override (plain string entry) preserves crowd-coding fallback', () {
      final config = DartclawConfig(
        sessions: const SessionConfig(scopeConfig: SessionScopeConfig.defaults()),
        governance: const GovernanceConfig(
          crowdCoding: CrowdCodingConfig(model: 'haiku', effort: 'low'),
        ),
      );
      // Plain-string equivalent: entry with no overrides — resolver returns null
      final resolver = GroupConfigResolver.fromChannelEntries({
        ChannelType.whatsapp: [const GroupEntry(id: 'group@g.us')],
      });

      final overrides = resolveChannelTurnOverrides(
        sessionKey: SessionKey.groupShared(channelType: 'whatsapp', groupId: 'group@g.us'),
        config: config,
        groupConfigResolver: resolver,
      );

      expect(overrides.model, 'haiku');
      expect(overrides.effort, 'low');
    });

    test('null resolver leaves existing chain unchanged', () {
      final config = DartclawConfig(
        sessions: const SessionConfig(scopeConfig: SessionScopeConfig.defaults()),
        governance: const GovernanceConfig(
          crowdCoding: CrowdCodingConfig(model: 'haiku', effort: 'low'),
        ),
      );

      final overrides = resolveChannelTurnOverrides(
        sessionKey: SessionKey.groupShared(channelType: 'whatsapp', groupId: 'group@g.us'),
        config: config,
      );

      expect(overrides.model, 'haiku');
      expect(overrides.effort, 'low');
    });

    test('DM session key with resolver does not apply per-group override', () {
      final config = DartclawConfig(
        sessions: const SessionConfig(scopeConfig: SessionScopeConfig.defaults()),
        governance: const GovernanceConfig(
          crowdCoding: CrowdCodingConfig(model: 'haiku', effort: 'low'),
        ),
      );
      final resolver = resolverWith(
        ChannelType.whatsapp,
        GroupEntry(id: '+123', model: 'opus', effort: 'high'),
      );

      final overrides = resolveChannelTurnOverrides(
        sessionKey: SessionKey.dmPerChannelContact(channelType: 'whatsapp', peerId: '+123'),
        config: config,
        groupConfigResolver: resolver,
      );

      // DM — crowd-coding does not apply, per-group does not apply
      expect(overrides.model, isNull);
      expect(overrides.effort, isNull);
    });
  });

  group('channelTypeFromSessionKey', () {
    test('extracts channel type from per-channel DM and group session keys', () {
      expect(
        channelTypeFromSessionKey(SessionKey.dmPerChannelContact(channelType: 'signal', peerId: '+123')),
        'signal',
      );
      expect(
        channelTypeFromSessionKey(SessionKey.groupPerMember(channelType: 'whatsapp', groupId: 'g', peerId: 'p')),
        'whatsapp',
      );
    });

    test('returns null for channel-agnostic or malformed session keys', () {
      expect(channelTypeFromSessionKey(SessionKey.dmShared()), isNull);
      expect(channelTypeFromSessionKey(SessionKey.dmPerContact(peerId: 'peer')), isNull);
      expect(channelTypeFromSessionKey('not-a-session-key'), isNull);
    });
  });
}

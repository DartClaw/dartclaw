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

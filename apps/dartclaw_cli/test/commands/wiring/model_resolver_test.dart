import 'package:dartclaw_cli/src/commands/wiring/model_resolver.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('resolveChannelTurnOverrides', () {
    final crowdCodingConfig = DartclawConfig(
      sessions: const SessionConfig(scopeConfig: SessionScopeConfig.defaults()),
      governance: const GovernanceConfig(
        crowdCoding: CrowdCodingConfig(model: 'haiku', effort: 'low'),
      ),
    );

    final cases = [
      (
        name: 'per-channel override wins over scope and crowd coding defaults',
        config: DartclawConfig(
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
        ),
        sessionKey: SessionKey.groupShared(channelType: 'google_chat', groupId: 'spaces/AAA'),
        expectedModel: 'opus',
        expectedEffort: 'high',
      ),
      (
        name: 'scope-level override applies when channel type is unavailable',
        config: DartclawConfig(
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
        ),
        sessionKey: SessionKey.dmPerContact(peerId: 'alice@example.com'),
        expectedModel: 'sonnet',
        expectedEffort: 'medium',
      ),
      (
        name: 'crowd coding default applies when no scope override exists',
        config: crowdCodingConfig,
        sessionKey: SessionKey.groupShared(channelType: 'whatsapp', groupId: 'group@g.us'),
        expectedModel: 'haiku',
        expectedEffort: 'low',
      ),
      (
        name: 'returns null overrides when no model settings are configured',
        config: const DartclawConfig.defaults(),
        sessionKey: SessionKey.groupShared(channelType: 'signal', groupId: 'group'),
        expectedModel: null,
        expectedEffort: null,
      ),
      (
        name: 'crowd coding defaults do not apply to DM sessions',
        config: crowdCodingConfig,
        sessionKey: SessionKey.dmPerChannelContact(channelType: 'signal', peerId: '+123'),
        expectedModel: null,
        expectedEffort: null,
      ),
      (
        name: 'non-channel sessions do not receive channel turn overrides',
        config: crowdCodingConfig,
        sessionKey: SessionKey.cronSession(jobId: 'daily-review'),
        expectedModel: null,
        expectedEffort: null,
      ),
    ];

    for (final testCase in cases) {
      test(testCase.name, () {
        final overrides = resolveChannelTurnOverrides(sessionKey: testCase.sessionKey, config: testCase.config);

        expect(overrides.model, testCase.expectedModel);
        expect(overrides.effort, testCase.expectedEffort);
      });
    }
  });

  group('resolveChannelTurnOverrides with GroupConfigResolver', () {
    GroupConfigResolver resolverWith(ChannelType type, GroupEntry entry) => GroupConfigResolver.fromChannelEntries({
      type: [entry],
    });

    final groupKey = SessionKey.groupShared(channelType: 'whatsapp', groupId: 'group@g.us');
    final crowdCodingConfig = DartclawConfig(
      sessions: const SessionConfig(scopeConfig: SessionScopeConfig.defaults()),
      governance: const GovernanceConfig(
        crowdCoding: CrowdCodingConfig(model: 'haiku', effort: 'low'),
      ),
    );

    final cases = [
      (
        name: 'per-group model+effort override wins over per-channel and crowd-coding',
        config: DartclawConfig(
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
        ),
        sessionKey: groupKey,
        resolver: resolverWith(ChannelType.whatsapp, GroupEntry(id: 'group@g.us', model: 'haiku', effort: 'low')),
        expectedModel: 'haiku',
        expectedEffort: 'low',
      ),
      (
        name: 'per-group effort-only override, model falls through to per-channel',
        config: DartclawConfig(
          sessions: SessionConfig(
            scopeConfig: SessionScopeConfig(
              dmScope: DmScope.perChannelContact,
              groupScope: GroupScope.shared,
              channels: {'whatsapp': const ChannelScopeConfig(model: 'opus')},
            ),
          ),
        ),
        sessionKey: groupKey,
        resolver: resolverWith(ChannelType.whatsapp, GroupEntry(id: 'group@g.us', effort: 'high')),
        expectedModel: 'opus',
        expectedEffort: 'high',
      ),
      (
        name: 'no per-group override preserves crowd-coding fallback',
        config: crowdCodingConfig,
        sessionKey: groupKey,
        resolver: resolverWith(ChannelType.whatsapp, const GroupEntry(id: 'group@g.us')),
        expectedModel: 'haiku',
        expectedEffort: 'low',
      ),
      (
        name: 'null resolver leaves existing chain unchanged',
        config: crowdCodingConfig,
        sessionKey: groupKey,
        resolver: null,
        expectedModel: 'haiku',
        expectedEffort: 'low',
      ),
      (
        name: 'DM session key with resolver does not apply per-group override',
        config: crowdCodingConfig,
        sessionKey: SessionKey.dmPerChannelContact(channelType: 'whatsapp', peerId: '+123'),
        resolver: resolverWith(ChannelType.whatsapp, GroupEntry(id: '+123', model: 'opus', effort: 'high')),
        expectedModel: null,
        expectedEffort: null,
      ),
    ];

    for (final testCase in cases) {
      test(testCase.name, () {
        final overrides = resolveChannelTurnOverrides(
          sessionKey: testCase.sessionKey,
          config: testCase.config,
          groupConfigResolver: testCase.resolver,
        );

        expect(overrides.model, testCase.expectedModel);
        expect(overrides.effort, testCase.expectedEffort);
      });
    }
  });

  group('channelTypeFromSessionKey', () {
    final cases = [
      (
        name: 'per-channel DM',
        sessionKey: SessionKey.dmPerChannelContact(channelType: 'signal', peerId: '+123'),
        expected: 'signal',
      ),
      (
        name: 'per-member group',
        sessionKey: SessionKey.groupPerMember(channelType: 'whatsapp', groupId: 'g', peerId: 'p'),
        expected: 'whatsapp',
      ),
      (name: 'shared DM', sessionKey: SessionKey.dmShared(), expected: null),
      (name: 'per-contact DM', sessionKey: SessionKey.dmPerContact(peerId: 'peer'), expected: null),
      (name: 'malformed key', sessionKey: 'not-a-session-key', expected: null),
    ];

    for (final testCase in cases) {
      test(testCase.name, () {
        expect(channelTypeFromSessionKey(testCase.sessionKey), testCase.expected);
      });
    }
  });
}

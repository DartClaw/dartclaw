import 'package:dartclaw_runtime/src/runtime/model_resolver.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
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

  group('resolveChannelTurnOverrides with an allowlist row', () {
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
        row: const GroupEntry(id: 'group@g.us', model: 'haiku', effort: 'low'),
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
        row: const GroupEntry(id: 'group@g.us', effort: 'high'),
        expectedModel: 'opus',
        expectedEffort: 'high',
      ),
      (
        name: 'a plain row preserves the crowd-coding fallback',
        config: crowdCodingConfig,
        sessionKey: groupKey,
        row: const GroupEntry(id: 'group@g.us'),
        expectedModel: 'haiku',
        expectedEffort: 'low',
      ),
      (
        name: 'a null row falls through the same chain',
        config: crowdCodingConfig,
        sessionKey: groupKey,
        row: null,
        expectedModel: 'haiku',
        expectedEffort: 'low',
      ),
      (
        name: 'a DM row resolves its model and effort through the same argument, with no crowd fallback',
        config: crowdCodingConfig,
        sessionKey: SessionKey.dmPerChannelContact(channelType: 'whatsapp', peerId: '+123'),
        row: const GroupEntry(id: '+123', model: 'opus', effort: 'high'),
        expectedModel: 'opus',
        expectedEffort: 'high',
      ),
      (
        name: 'a DM row carrying only agent leaves model and effort to the channel and scope',
        config: DartclawConfig(
          sessions: SessionConfig(
            scopeConfig: SessionScopeConfig(
              dmScope: DmScope.perChannelContact,
              groupScope: GroupScope.shared,
              channels: {'signal': const ChannelScopeConfig(model: 'opus')},
              effort: 'medium',
            ),
          ),
        ),
        sessionKey: SessionKey.dmPerChannelContact(channelType: 'signal', peerId: '+123'),
        row: const GroupEntry(id: '+123', agent: 'ana'),
        expectedModel: 'opus',
        expectedEffort: 'medium',
      ),
    ];

    for (final testCase in cases) {
      test(testCase.name, () {
        final overrides = resolveChannelTurnOverrides(
          sessionKey: testCase.sessionKey,
          config: testCase.config,
          row: testCase.row,
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

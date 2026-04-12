import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:test/test.dart';

void main() {
  group('DmScope', () {
    test('fromYaml maps all valid values', () {
      expect(DmScope.fromYaml('shared'), DmScope.shared);
      expect(DmScope.fromYaml('per-contact'), DmScope.perContact);
      expect(DmScope.fromYaml('per-channel-contact'), DmScope.perChannelContact);
    });

    test('fromYaml returns null for unknown value', () {
      expect(DmScope.fromYaml('invalid'), isNull);
      expect(DmScope.fromYaml(''), isNull);
      expect(DmScope.fromYaml('perContact'), isNull);
    });

    test('fromYaml accepts snake_case variants', () {
      expect(DmScope.fromYaml('per_contact'), DmScope.perContact);
      expect(DmScope.fromYaml('per_channel_contact'), DmScope.perChannelContact);
      // kebab-case still works
      expect(DmScope.fromYaml('per-contact'), DmScope.perContact);
      expect(DmScope.fromYaml('per-channel-contact'), DmScope.perChannelContact);
    });

    test('toYaml round-trips correctly', () {
      for (final scope in DmScope.values) {
        expect(DmScope.fromYaml(scope.toYaml()), scope);
      }
    });
  });

  group('GroupScope', () {
    test('fromYaml parses and round-trips all valid values', () {
      expect(GroupScope.fromYaml('shared'), GroupScope.shared);
      expect(GroupScope.fromYaml('per-member'), GroupScope.perMember);
      expect(GroupScope.fromYaml('invalid'), isNull);
      for (final scope in GroupScope.values) {
        expect(GroupScope.fromYaml(scope.toYaml()), scope);
      }
    });

    test('fromYaml accepts snake_case variants', () {
      expect(GroupScope.fromYaml('per_member'), GroupScope.perMember);
      // kebab-case still works
      expect(GroupScope.fromYaml('per-member'), GroupScope.perMember);
    });
  });

  group('SessionScopeConfig', () {
    test('defaults() has expected values', () {
      const config = SessionScopeConfig.defaults();
      expect(config.dmScope, DmScope.perChannelContact);
      expect(config.groupScope, GroupScope.shared);
      expect(config.channels, isEmpty);
      expect(config.model, isNull);
      expect(config.effort, isNull);
    });

    group('forChannel', () {
      test('no override returns global defaults', () {
        const config = SessionScopeConfig.defaults();
        final result = config.forChannel('whatsapp');
        expect(result.dmScope, DmScope.perChannelContact);
        expect(result.groupScope, GroupScope.shared);
      });

      test('dmScope override returns override for dm, global for group', () {
        final config = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {'signal': const ChannelScopeConfig(dmScope: DmScope.perChannelContact)},
        );
        final result = config.forChannel('signal');
        expect(result.dmScope, DmScope.perChannelContact);
        expect(result.groupScope, GroupScope.shared);
      });

      test('both overrides returns both overrides', () {
        final config = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {
            'signal': const ChannelScopeConfig(
              dmScope: DmScope.shared,
              groupScope: GroupScope.perMember,
              model: 'haiku',
              effort: 'low',
            ),
          },
          model: 'sonnet',
          effort: 'medium',
        );
        final result = config.forChannel('signal');
        expect(result.dmScope, DmScope.shared);
        expect(result.groupScope, GroupScope.perMember);
        expect(result.model, 'haiku');
        expect(result.effort, 'low');
      });

      test('unknown channel returns global defaults', () {
        final config = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {'signal': const ChannelScopeConfig(dmScope: DmScope.shared)},
          model: 'sonnet',
          effort: 'medium',
        );
        final result = config.forChannel('unknown');
        expect(result.dmScope, DmScope.perContact);
        expect(result.groupScope, GroupScope.shared);
        expect(result.model, 'sonnet');
        expect(result.effort, 'medium');
      });

      test('channel model override falls back to scope when absent', () {
        final config = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {'signal': const ChannelScopeConfig(groupScope: GroupScope.perMember)},
          model: 'haiku',
          effort: 'high',
        );
        final result = config.forChannel('signal');
        expect(result.model, 'haiku');
        expect(result.effort, 'high');
      });
    });

    test('hashCode is stable across channel insertion order', () {
      final first = SessionScopeConfig(
        dmScope: DmScope.perContact,
        groupScope: GroupScope.shared,
        channels: {
          'signal': const ChannelScopeConfig(groupScope: GroupScope.perMember, model: 'haiku'),
          'googlechat': const ChannelScopeConfig(dmScope: DmScope.shared, effort: 'low'),
        },
      );
      final second = SessionScopeConfig(
        dmScope: DmScope.perContact,
        groupScope: GroupScope.shared,
        channels: {
          'googlechat': const ChannelScopeConfig(dmScope: DmScope.shared, effort: 'low'),
          'signal': const ChannelScopeConfig(groupScope: GroupScope.perMember, model: 'haiku'),
        },
      );

      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });
  });
}

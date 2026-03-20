import 'package:dartclaw_core/dartclaw_core.dart';
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
          channels: {'signal': const ChannelScopeConfig(dmScope: DmScope.shared, groupScope: GroupScope.perMember)},
        );
        final result = config.forChannel('signal');
        expect(result.dmScope, DmScope.shared);
        expect(result.groupScope, GroupScope.perMember);
      });

      test('unknown channel returns global defaults', () {
        final config = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {'signal': const ChannelScopeConfig(dmScope: DmScope.shared)},
        );
        final result = config.forChannel('unknown');
        expect(result.dmScope, DmScope.perContact);
        expect(result.groupScope, GroupScope.shared);
      });
    });
  });
}

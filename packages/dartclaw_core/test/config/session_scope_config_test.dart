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

    test('toYaml round-trips correctly', () {
      for (final scope in DmScope.values) {
        expect(DmScope.fromYaml(scope.toYaml()), scope);
      }
    });
  });

  group('GroupScope', () {
    test('fromYaml maps all valid values', () {
      expect(GroupScope.fromYaml('shared'), GroupScope.shared);
      expect(GroupScope.fromYaml('per-member'), GroupScope.perMember);
    });

    test('fromYaml returns null for unknown value', () {
      expect(GroupScope.fromYaml('invalid'), isNull);
      expect(GroupScope.fromYaml(''), isNull);
      expect(GroupScope.fromYaml('perMember'), isNull);
    });

    test('toYaml round-trips correctly', () {
      for (final scope in GroupScope.values) {
        expect(GroupScope.fromYaml(scope.toYaml()), scope);
      }
    });
  });

  group('ChannelScopeConfig', () {
    test('empty() has both fields null', () {
      const config = ChannelScopeConfig.empty();
      expect(config.dmScope, isNull);
      expect(config.groupScope, isNull);
    });

    test('equality: same fields are equal', () {
      const a = ChannelScopeConfig(dmScope: DmScope.shared);
      const b = ChannelScopeConfig(dmScope: DmScope.shared);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('equality: different fields are not equal', () {
      const a = ChannelScopeConfig(dmScope: DmScope.shared);
      const b = ChannelScopeConfig(dmScope: DmScope.perContact);
      expect(a, isNot(equals(b)));
    });

    test('equality: both null vs one set', () {
      const a = ChannelScopeConfig.empty();
      const b = ChannelScopeConfig(groupScope: GroupScope.perMember);
      expect(a, isNot(equals(b)));
    });
  });

  group('SessionScopeConfig', () {
    test('defaults() has expected values', () {
      const config = SessionScopeConfig.defaults();
      expect(config.dmScope, DmScope.perContact);
      expect(config.groupScope, GroupScope.shared);
      expect(config.channels, isEmpty);
    });

    group('forChannel', () {
      test('no override returns global defaults', () {
        const config = SessionScopeConfig.defaults();
        final result = config.forChannel('whatsapp');
        expect(result.dmScope, DmScope.perContact);
        expect(result.groupScope, GroupScope.shared);
      });

      test('dmScope override returns override for dm, global for group', () {
        final config = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {
            'signal': const ChannelScopeConfig(dmScope: DmScope.perChannelContact),
          },
        );
        final result = config.forChannel('signal');
        expect(result.dmScope, DmScope.perChannelContact);
        expect(result.groupScope, GroupScope.shared);
      });

      test('groupScope override returns override for group, global for dm', () {
        final config = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {
            'signal': const ChannelScopeConfig(groupScope: GroupScope.perMember),
          },
        );
        final result = config.forChannel('signal');
        expect(result.dmScope, DmScope.perContact);
        expect(result.groupScope, GroupScope.perMember);
      });

      test('both overrides returns both overrides', () {
        final config = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {
            'signal': const ChannelScopeConfig(
              dmScope: DmScope.shared,
              groupScope: GroupScope.perMember,
            ),
          },
        );
        final result = config.forChannel('signal');
        expect(result.dmScope, DmScope.shared);
        expect(result.groupScope, GroupScope.perMember);
      });

      test('unknown channel returns global defaults', () {
        final config = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {
            'signal': const ChannelScopeConfig(dmScope: DmScope.shared),
          },
        );
        final result = config.forChannel('unknown');
        expect(result.dmScope, DmScope.perContact);
        expect(result.groupScope, GroupScope.shared);
      });
    });

    group('equality', () {
      test('same fields are equal', () {
        const a = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
        );
        const b = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
        );
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('different dmScope are not equal', () {
        const a = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
        );
        const b = SessionScopeConfig(
          dmScope: DmScope.shared,
          groupScope: GroupScope.shared,
        );
        expect(a, isNot(equals(b)));
      });

      test('different channels map are not equal', () {
        final a = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {
            'signal': const ChannelScopeConfig(dmScope: DmScope.shared),
          },
        );
        const b = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
        );
        expect(a, isNot(equals(b)));
      });

      test('same channels map are equal', () {
        final a = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {
            'signal': const ChannelScopeConfig(groupScope: GroupScope.perMember),
          },
        );
        final b = SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {
            'signal': const ChannelScopeConfig(groupScope: GroupScope.perMember),
          },
        );
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });
    });
  });
}

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('GroupConfigResolver.resolve', () {
    test('returns structured GroupEntry by (ChannelType, groupId)', () {
      final resolver = GroupConfigResolver.fromChannelEntries({
        ChannelType.whatsapp: [
          const GroupEntry(id: 'grp-1', name: 'Dev Team'),
        ],
      });
      final result = resolver.resolve(ChannelType.whatsapp, 'grp-1');
      expect(result, isNotNull);
      expect(result!.id, 'grp-1');
      expect(result.name, 'Dev Team');
    });

    test('returns null for plain-string entry (no overrides)', () {
      final resolver = GroupConfigResolver.fromChannelEntries({
        ChannelType.whatsapp: [
          const GroupEntry(id: 'grp-plain'),
        ],
      });
      expect(resolver.resolve(ChannelType.whatsapp, 'grp-plain'), isNull);
    });

    test('returns null for unknown groupId', () {
      final resolver = GroupConfigResolver.fromChannelEntries({
        ChannelType.whatsapp: [const GroupEntry(id: 'grp-1', name: 'Team')],
      });
      expect(resolver.resolve(ChannelType.whatsapp, 'grp-unknown'), isNull);
    });

    test('returns null for wrong channel type', () {
      final resolver = GroupConfigResolver.fromChannelEntries({
        ChannelType.whatsapp: [const GroupEntry(id: 'grp-1', name: 'Team')],
      });
      expect(resolver.resolve(ChannelType.signal, 'grp-1'), isNull);
    });

    test('empty entries resolver always returns null', () {
      final resolver = GroupConfigResolver.fromChannelEntries({});
      expect(resolver.resolve(ChannelType.whatsapp, 'grp-1'), isNull);
    });

    test('structured entry with name only is stored and resolvable', () {
      final resolver = GroupConfigResolver.fromChannelEntries({
        ChannelType.googlechat: [
          const GroupEntry(id: 'spaces/AAA', name: 'Main Space'),
        ],
      });
      final result = resolver.resolve(ChannelType.googlechat, 'spaces/AAA');
      expect(result, isNotNull);
      expect(result!.name, 'Main Space');
      expect(result.project, isNull);
    });

    test('entry with only id (no overrides) is not stored', () {
      final resolver = GroupConfigResolver.fromChannelEntries({
        ChannelType.signal: [
          const GroupEntry(id: 'grp-1'),
        ],
      });
      expect(resolver.resolve(ChannelType.signal, 'grp-1'), isNull);
    });
  });

  group('GroupConfigResolver.normalizeConfigKey', () {
    test('google_chat -> ChannelType.googlechat', () {
      expect(GroupConfigResolver.normalizeConfigKey('google_chat'), ChannelType.googlechat);
    });

    test('whatsapp -> ChannelType.whatsapp', () {
      expect(GroupConfigResolver.normalizeConfigKey('whatsapp'), ChannelType.whatsapp);
    });

    test('signal -> ChannelType.signal', () {
      expect(GroupConfigResolver.normalizeConfigKey('signal'), ChannelType.signal);
    });

    test('unknown key returns null', () {
      expect(GroupConfigResolver.normalizeConfigKey('unknown'), isNull);
    });

    test('googlechat (no underscore) -> ChannelType.googlechat', () {
      expect(GroupConfigResolver.normalizeConfigKey('googlechat'), ChannelType.googlechat);
    });
  });
}

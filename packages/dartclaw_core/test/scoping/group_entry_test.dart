import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('GroupEntry.parseList', () {
    test('null input returns empty list', () {
      expect(GroupEntry.parseList(null), isEmpty);
    });

    test('empty list returns empty list', () {
      expect(GroupEntry.parseList([]), isEmpty);
    });

    test('plain strings produce GroupEntry with id only, all overrides null', () {
      final result = GroupEntry.parseList(['grp-1', 'grp-2']);
      expect(result, hasLength(2));
      expect(result[0].id, 'grp-1');
      expect(result[0].name, isNull);
      expect(result[0].project, isNull);
      expect(result[0].model, isNull);
      expect(result[0].effort, isNull);
      expect(result[1].id, 'grp-2');
    });

    test('structured map with all fields produces correct GroupEntry', () {
      final result = GroupEntry.parseList([
        {'id': 'grp-1', 'name': 'Dev Team', 'project': 'proj-abc', 'model': 'sonnet', 'effort': 'medium'},
      ]);
      expect(result, hasLength(1));
      expect(result[0].id, 'grp-1');
      expect(result[0].name, 'Dev Team');
      expect(result[0].project, 'proj-abc');
      expect(result[0].model, 'sonnet');
      expect(result[0].effort, 'medium');
    });

    test('structured map with only id produces same as plain string', () {
      final result = GroupEntry.parseList([
        {'id': 'grp-1'},
      ]);
      expect(result, hasLength(1));
      expect(result[0].id, 'grp-1');
      expect(result[0].name, isNull);
      expect(result[0].project, isNull);
      expect(result[0].model, isNull);
      expect(result[0].effort, isNull);
    });

    test('map without id is skipped and warning emitted', () {
      final warns = <String>[];
      final result = GroupEntry.parseList([
        {'name': 'No ID'},
      ], onWarning: warns.add);
      expect(result, isEmpty);
      expect(warns, hasLength(1));
      expect(warns[0], contains('missing or invalid'));
    });

    test('non-string/non-map item (int) is skipped and warning emitted', () {
      final warns = <String>[];
      final result = GroupEntry.parseList([42, true], onWarning: warns.add);
      expect(result, isEmpty);
      expect(warns, hasLength(2));
    });

    test('duplicate IDs: last entry wins and warning emitted', () {
      final warns = <String>[];
      final result = GroupEntry.parseList([
        {'id': 'grp-1', 'name': 'First'},
        {'id': 'grp-1', 'name': 'Second'},
      ], onWarning: warns.add);
      expect(result, hasLength(1));
      expect(result[0].name, 'Second');
      expect(warns, hasLength(1));
      expect(warns[0], contains('duplicate'));
    });

    test('whitespace-only name is treated as null', () {
      final result = GroupEntry.parseList([
        {'id': 'grp-1', 'name': '   '},
      ]);
      expect(result[0].name, isNull);
    });

    test('unknown keys in map are ignored and warning emitted', () {
      final warns = <String>[];
      final result = GroupEntry.parseList([
        {'id': 'grp-1', 'unknown_key': 'value'},
      ], onWarning: warns.add);
      expect(result, hasLength(1));
      expect(result[0].id, 'grp-1');
      expect(warns, hasLength(1));
      expect(warns[0], contains('unknown key'));
    });

    test('mixed list (strings + maps) produces correct combined result', () {
      final warns = <String>[];
      final result = GroupEntry.parseList([
        'grp-plain',
        {'id': 'grp-structured', 'name': 'Team'},
        42,
      ], onWarning: warns.add);
      expect(result, hasLength(2));
      expect(result[0].id, 'grp-plain');
      expect(result[0].name, isNull);
      expect(result[1].id, 'grp-structured');
      expect(result[1].name, 'Team');
      expect(warns, hasLength(1));
    });

    test('groupIds convenience: matches expected ID list', () {
      final entries = GroupEntry.parseList(['a', 'b', 'c']);
      expect(GroupEntry.groupIds(entries), ['a', 'b', 'c']);
    });

    test('backward compat: list of plain strings produces identical groupIds to old _parseStringList output', () {
      final raw = ['grp-1', 'grp-2', 'grp-3'];
      final entries = GroupEntry.parseList(raw);
      expect(GroupEntry.groupIds(entries), raw);
    });

    test('map with empty string id is skipped and warning emitted', () {
      final warns = <String>[];
      final result = GroupEntry.parseList([
        {'id': ''},
      ], onWarning: warns.add);
      expect(result, isEmpty);
      expect(warns, hasLength(1));
    });
  });

  group('GroupEntry equality', () {
    test('equal when all fields match', () {
      const a = GroupEntry(id: 'g1', name: 'Team', project: 'p', model: 'm', effort: 'e');
      const b = GroupEntry(id: 'g1', name: 'Team', project: 'p', model: 'm', effort: 'e');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('not equal when id differs', () {
      const a = GroupEntry(id: 'g1');
      const b = GroupEntry(id: 'g2');
      expect(a, isNot(equals(b)));
    });
  });

  group('GroupEntry.toString', () {
    test('includes id and override fields', () {
      const entry = GroupEntry(id: 'g1', name: 'Team');
      final str = entry.toString();
      expect(str, contains('g1'));
      expect(str, contains('Team'));
    });
  });
}

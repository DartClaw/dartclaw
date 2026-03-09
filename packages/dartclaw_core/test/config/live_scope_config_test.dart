import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('LiveScopeConfig', () {
    test('current returns initial config', () {
      const initial = SessionScopeConfig(dmScope: DmScope.shared, groupScope: GroupScope.shared);
      final live = LiveScopeConfig(initial);

      expect(live.current, initial);
    });

    test('update replaces current config', () {
      final live = LiveScopeConfig(const SessionScopeConfig(dmScope: DmScope.shared, groupScope: GroupScope.shared));
      const updated = SessionScopeConfig(dmScope: DmScope.perContact, groupScope: GroupScope.perMember);

      live.update(updated);

      expect(live.current, updated);
    });

    test('update is visible to subsequent reads', () {
      final live = LiveScopeConfig(
        const SessionScopeConfig(dmScope: DmScope.perContact, groupScope: GroupScope.shared),
      );

      live.update(const SessionScopeConfig(dmScope: DmScope.perChannelContact, groupScope: GroupScope.perMember));

      expect(live.current.dmScope, DmScope.perChannelContact);
      expect(live.current.groupScope, GroupScope.perMember);
    });
  });
}

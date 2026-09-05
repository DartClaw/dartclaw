import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:test/test.dart';

void main() {
  group('resolveSpaceType', () {
    test('the deprecated type key wins when both are present', () {
      expect(resolveSpaceType({'type': 'DM', 'spaceType': 'SPACE'}), 'DM');
      expect(resolveSpaceType({'type': 'ROOM', 'spaceType': 'DIRECT_MESSAGE'}), 'ROOM');
    });

    test('the current key is read when the deprecated one is absent', () {
      expect(resolveSpaceType({'spaceType': 'DIRECT_MESSAGE'}), 'DM');
      expect(resolveSpaceType({'spaceType': 'SPACE'}), 'SPACE');
      expect(resolveSpaceType({'spaceType': 'GROUP_CHAT'}), 'GROUP_CHAT');
    });

    // A space that cannot be proven to be a named space is access-checked as a
    // direct message rather than admitted under the group policy.
    test('a resource carrying no usable space type fails closed to DM', () {
      expect(resolveSpaceType(null), 'DM');
      expect(resolveSpaceType(const {}), 'DM');
      expect(resolveSpaceType(const {'name': 'spaces/AAAA'}), 'DM');
      expect(resolveSpaceType(const {'type': 42, 'spaceType': 42}), 'DM');
    });

    test('a non-string deprecated key falls through to the current key', () {
      expect(resolveSpaceType(const {'type': 42, 'spaceType': 'SPACE'}), 'SPACE');
    });

    // The Space Events path proves its space kind by construction (only named
    // spaces carry subscriptions), so it may widen the fallback — but nothing
    // else about the resolution changes with it.
    test('an explicit fallback applies only when no usable key is present', () {
      expect(resolveSpaceType(null, fallback: 'SPACE'), 'SPACE');
      expect(resolveSpaceType(const {'name': 'spaces/AAAA'}, fallback: 'SPACE'), 'SPACE');
      expect(resolveSpaceType(const {'spaceType': 'DIRECT_MESSAGE'}, fallback: 'SPACE'), 'DM');
      expect(resolveSpaceType(const {'type': 'ROOM'}, fallback: 'SPACE'), 'ROOM');
    });
  });

  group('resolveGroupJid', () {
    test('a direct message has no group context under either spelling', () {
      expect(resolveGroupJid(spaceType: 'DM', spaceName: 'spaces/AAAA'), isNull);
      expect(resolveGroupJid(spaceType: 'DIRECT_MESSAGE', spaceName: 'spaces/AAAA'), isNull);
    });

    test('a named space keeps its space name as the group jid', () {
      expect(resolveGroupJid(spaceType: 'ROOM', spaceName: 'spaces/GRP'), 'spaces/GRP');
      expect(resolveGroupJid(spaceType: 'SPACE', spaceName: 'spaces/GRP'), 'spaces/GRP');
      expect(resolveGroupJid(spaceType: 'UNKNOWN_FUTURE', spaceName: 'spaces/GRP'), 'spaces/GRP');
    });
  });
}

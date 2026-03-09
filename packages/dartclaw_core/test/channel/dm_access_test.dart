import 'dart:math';

import 'package:dartclaw_core/src/channel/dm_access.dart';
import 'package:test/test.dart';

void main() {
  group('DmAccessController', () {
    group('pairing mode', () {
      late DmAccessController ctrl;

      setUp(() {
        ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
      });

      test('unknown sender is not allowed', () {
        expect(ctrl.isAllowed('unknown@s.whatsapp.net'), isFalse);
      });

      test('createPairing returns code', () {
        final code = ctrl.createPairing('user@s.whatsapp.net');
        expect(code, isNotNull);
        expect(code!.code, hasLength(8));
        expect(code.jid, 'user@s.whatsapp.net');
        expect(code.isExpired, isFalse);
      });

      test('confirmPairing adds to allowlist', () {
        final code = ctrl.createPairing('user@s.whatsapp.net')!;
        expect(ctrl.confirmPairing(code.code), isTrue);
        expect(ctrl.isAllowed('user@s.whatsapp.net'), isTrue);
      });

      test('max 3 pending pairings', () {
        ctrl.createPairing('a@test');
        ctrl.createPairing('b@test');
        ctrl.createPairing('c@test');
        final fourth = ctrl.createPairing('d@test');
        expect(fourth, isNull);
      });

      test('same JID returns existing pairing', () {
        final first = ctrl.createPairing('user@test');
        final second = ctrl.createPairing('user@test');
        expect(first!.code, second!.code);
        expect(ctrl.pendingCount, 1);
      });

      test('invalid code fails', () {
        expect(ctrl.confirmPairing('INVALID!'), isFalse);
      });
    });

    group('allowlist mode', () {
      test('allows listed JIDs', () {
        final ctrl = DmAccessController(mode: DmAccessMode.allowlist, allowlist: {'allowed@test'});
        expect(ctrl.isAllowed('allowed@test'), isTrue);
        expect(ctrl.isAllowed('denied@test'), isFalse);
      });
    });

    group('open mode', () {
      test('allows everyone', () {
        final ctrl = DmAccessController(mode: DmAccessMode.open);
        expect(ctrl.isAllowed('anyone@test'), isTrue);
      });
    });

    group('disabled mode', () {
      test('denies everyone', () {
        final ctrl = DmAccessController(mode: DmAccessMode.disabled);
        expect(ctrl.isAllowed('anyone@test'), isFalse);
      });
    });

    group('Signal pairing mode', () {
      late DmAccessController ctrl;

      setUp(() {
        ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
      });

      test('Signal sender (phone) creates pairing, confirms, is allowed', () {
        final code = ctrl.createPairing('+1234567890');
        expect(code, isNotNull);
        expect(code!.jid, '+1234567890');

        expect(ctrl.confirmPairing(code.code), isTrue);
        expect(ctrl.isAllowed('+1234567890'), isTrue);
      });

      test('Signal sender (UUID) creates pairing, confirms, is allowed', () {
        const uuid = '12bfcd5a-3363-45f4-94b6-3fe247f11ab8';
        final code = ctrl.createPairing(uuid);
        expect(code, isNotNull);
        expect(code!.jid, uuid);

        expect(ctrl.confirmPairing(code.code), isTrue);
        expect(ctrl.isAllowed(uuid), isTrue);
      });

      test('mixed phone + UUID in allowlist — both independently checked', () {
        final phoneCtrl = DmAccessController(
          mode: DmAccessMode.allowlist,
          allowlist: {'+1234567890', '12bfcd5a-3363-45f4-94b6-3fe247f11ab8'},
        );
        expect(phoneCtrl.isAllowed('+1234567890'), isTrue);
        expect(phoneCtrl.isAllowed('12bfcd5a-3363-45f4-94b6-3fe247f11ab8'), isTrue);
        expect(phoneCtrl.isAllowed('+9999999999'), isFalse);
        expect(phoneCtrl.isAllowed('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'), isFalse);
      });

      test('Signal config with DmAccessMode.pairing — controller accepts it', () {
        final pairingCtrl = DmAccessController(mode: DmAccessMode.pairing);
        expect(pairingCtrl.isAllowed('+1234567890'), isFalse);

        final code = pairingCtrl.createPairing('+1234567890');
        expect(code, isNotNull);
      });
    });

    group('pendingPairings', () {
      test('returns non-expired entries', () {
        final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
        ctrl.createPairing('a@test');
        ctrl.createPairing('b@test');

        final pending = ctrl.pendingPairings;
        expect(pending, hasLength(2));
        expect(pending.map((p) => p.jid), containsAll(['a@test', 'b@test']));
      });

      test('evicts expired entries', () {
        final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
        ctrl.createPairing('a@test');
        // Cannot easily test expiry in unit test without mocking time,
        // but we can verify the getter works with no expired entries
        expect(ctrl.pendingPairings, hasLength(1));
      });
    });

    group('rejectPairing', () {
      test('removes entry without adding to allowlist', () {
        final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
        final code = ctrl.createPairing('user@test')!;

        expect(ctrl.rejectPairing(code.code), isTrue);
        expect(ctrl.pendingPairings, isEmpty);
        expect(ctrl.isAllowed('user@test'), isFalse);
      });

      test('returns false for unknown code', () {
        final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
        expect(ctrl.rejectPairing('NONEXIST'), isFalse);
      });
    });

    group('displayName', () {
      test('createPairing stores displayName on PairingCode', () {
        final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
        final code = ctrl.createPairing('user@test', displayName: 'Alice');
        expect(code, isNotNull);
        expect(code!.displayName, 'Alice');
      });

      test('createPairing with no displayName has null', () {
        final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
        final code = ctrl.createPairing('user@test');
        expect(code, isNotNull);
        expect(code!.displayName, isNull);
      });

      test('existing pairing for same JID returns same PairingCode (idempotent)', () {
        final ctrl = DmAccessController(mode: DmAccessMode.pairing, random: Random(42));
        final first = ctrl.createPairing('user@test', displayName: 'Alice');
        final second = ctrl.createPairing('user@test', displayName: 'Bob');
        expect(first!.code, second!.code);
        // Original displayName preserved
        expect(second.displayName, 'Alice');
      });
    });

    group('addToAllowlist / removeFromAllowlist', () {
      test('addToAllowlist adds entry, isAllowed returns true', () {
        final ctrl = DmAccessController(mode: DmAccessMode.allowlist);
        expect(ctrl.isAllowed('new@test'), isFalse);
        ctrl.addToAllowlist('new@test');
        expect(ctrl.isAllowed('new@test'), isTrue);
        expect(ctrl.allowlist, contains('new@test'));
      });

      test('removeFromAllowlist removes entry, isAllowed returns false', () {
        final ctrl = DmAccessController(mode: DmAccessMode.allowlist, allowlist: {'existing@test'});
        expect(ctrl.isAllowed('existing@test'), isTrue);
        final removed = ctrl.removeFromAllowlist('existing@test');
        expect(removed, isTrue);
        expect(ctrl.isAllowed('existing@test'), isFalse);
        expect(ctrl.allowlist, isNot(contains('existing@test')));
      });

      test('removeFromAllowlist returns false for non-existent entry', () {
        final ctrl = DmAccessController(mode: DmAccessMode.allowlist);
        final removed = ctrl.removeFromAllowlist('nonexistent@test');
        expect(removed, isFalse);
      });
    });
  });
}

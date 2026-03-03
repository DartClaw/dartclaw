import 'dart:math';

import 'package:dartclaw_core/src/channel/whatsapp/whatsapp_config.dart';
import 'package:dartclaw_core/src/channel/whatsapp/dm_access.dart';
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
  });
}

import 'dart:convert';

import 'package:dartclaw_runtime/src/web/web_utils.dart';
import 'package:test/test.dart';

void main() {
  group('toastTriggerHeader', () {
    test('carries the toast payload the browser controller listens for', () {
      final header = toastTriggerHeader('success', 'Project added');

      expect(header.keys, ['HX-Trigger-After-Swap']);
      expect(jsonDecode(header['HX-Trigger-After-Swap']!), {
        'dc:toast': {'type': 'success', 'message': 'Project added'},
      });
    });

    test('a message outside Latin-1 survives the header as an escaped round trip', () {
      const message = 'Kunde inte hämta projektet "smiðia" — 完了';

      final value = toastTriggerHeader('error', message)['HX-Trigger-After-Swap']!;

      // A header carrying a non-Latin-1 byte is mangled on the wire, so the
      // payload must reach the client as ASCII and decode back to the original.
      expect(
        value.codeUnits.every((unit) => unit >= 0x20 && unit <= 0x7e),
        isTrue,
        reason: 'header value must be printable ASCII, was: $value',
      );
      expect((jsonDecode(value) as Map)['dc:toast']['message'], message);
    });

    test('a control character cannot break the header into a second one', () {
      final value = toastTriggerHeader('error', 'line one\r\nX-Injected: yes')['HX-Trigger-After-Swap']!;

      expect(value, isNot(contains('\r')));
      expect(value, isNot(contains('\n')));
      expect((jsonDecode(value) as Map)['dc:toast']['message'], 'line one\r\nX-Injected: yes');
    });
  });
}

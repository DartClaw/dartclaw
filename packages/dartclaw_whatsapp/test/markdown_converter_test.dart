import 'package:dartclaw_whatsapp/src/markdown_converter.dart';
import 'package:test/test.dart';

void main() {
  group('markdownToWhatsApp', () {
    test('converts standard emphasis, headings, links, and tables', () {
      const input = '''## Summary

Use **bold**, *italic*, ~~old~~, and [docs](https://example.com).

| Item | State |
| --- | --- |
| Build | **Pass** |''';

      expect(markdownToWhatsApp(input), '''*Summary*

Use *bold*, _italic_, ~old~, and docs (https://example.com).

Item | State
Build | *Pass*''');
    });

    test('does not convert Markdown-like content inside code', () {
      const input = '''**outside**
```dart
final value = "**inside**";
```''';

      expect(markdownToWhatsApp(input), '''*outside*
```
final value = "**inside**";
```''');
    });

    test('preserves escaped formatting markers', () {
      expect(markdownToWhatsApp(r'\*literal\* and **bold**'), r'\*literal\* and *bold*');
    });

    test('flattens redundant heading bold and preserves italic', () {
      expect(markdownToWhatsApp('## **Bold** and ***both***'), '*Bold and _both_*');
    });

    test('converts nested bullets and reference links', () {
      const input = '* parent\n  * child\n\n[docs][guide]\n\n[guide]: https://docs.example.com';

      expect(markdownToWhatsApp(input).trimRight(), '- parent\n  - child\n\ndocs (https://docs.example.com)');
    });

    test('converts reference images and preserves unresolved references', () {
      const input = '![diagram][asset] [missing][unknown]\n\n[asset]: https://img.example.com/diagram.png';

      expect(markdownToWhatsApp(input).trimRight(), 'diagram (https://img.example.com/diagram.png) [missing][unknown]');
    });
  });
}

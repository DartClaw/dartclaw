import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('generateQrSvg', () {
    test('returns SVG markup with QR rects', () {
      final svg = generateQrSvg('https://workshop.example.com/canvas/demo-token');

      expect(svg, startsWith('<svg'));
      expect(svg, contains('viewBox='));
      expect(svg, contains('<rect'));
      expect(svg, endsWith('</svg>'));
    });

    test('handles URL with special characters', () {
      final svg = generateQrSvg('https://example.com/canvas/abc+def=123&x=y');
      expect(svg, startsWith('<svg'));
      expect(svg, contains('<rect'));
    });

    test('produces different SVG for different data', () {
      final svg1 = generateQrSvg('https://a.example.com/token1');
      final svg2 = generateQrSvg('https://b.example.com/token2');
      expect(svg1, isNot(equals(svg2)));
    });
  });
}

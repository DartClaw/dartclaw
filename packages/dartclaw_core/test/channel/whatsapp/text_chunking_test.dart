import 'package:dartclaw_core/src/channel/whatsapp/text_chunking.dart';
import 'package:test/test.dart';

void main() {
  group('chunkText', () {
    test('short text returns single chunk', () {
      expect(chunkText('hello', maxSize: 100), ['hello']);
    });

    test('splits at paragraph break', () {
      final text = '${'a' * 50}\n\n${'b' * 50}';
      final chunks = chunkText(text, maxSize: 60);
      expect(chunks, hasLength(2));
      expect(chunks[0], startsWith('(1/2)'));
      expect(chunks[0], contains('a' * 50));
      expect(chunks[1], startsWith('(2/2)'));
      expect(chunks[1], contains('b' * 50));
    });

    test('splits at line break', () {
      final text = '${'a' * 50}\n${'b' * 50}';
      final chunks = chunkText(text, maxSize: 60);
      expect(chunks, hasLength(2));
    });

    test('splits at sentence break', () {
      final text = '${'a' * 40}. ${'b' * 40}';
      final chunks = chunkText(text, maxSize: 50);
      expect(chunks, hasLength(2));
    });

    test('splits at word break', () {
      final text = '${'a' * 40} ${'b' * 40}';
      final chunks = chunkText(text, maxSize: 50);
      expect(chunks, hasLength(2));
    });

    test('hard break when no natural breaks', () {
      final text = 'a' * 100;
      final chunks = chunkText(text, maxSize: 40);
      expect(chunks.length, greaterThan(1));
    });

    test('exactly maxSize returns single chunk', () {
      final text = 'a' * 100;
      expect(chunkText(text, maxSize: 100), hasLength(1));
    });

    test('chunk indicators are correct', () {
      final text = 'hello world. foo bar. baz qux.';
      final chunks = chunkText(text, maxSize: 15);
      expect(chunks.length, greaterThan(1));
      for (var i = 0; i < chunks.length; i++) {
        expect(chunks[i], startsWith('(${i + 1}/${chunks.length})'));
      }
    });
  });
}

import 'package:dartclaw_core/src/channel/text_chunking.dart';
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
      expect(chunks.every((chunk) => chunk.length <= 40), isTrue);
    });

    test('rejects non-positive max sizes', () {
      expect(() => chunkText('text', maxSize: 0), throwsArgumentError);
      expect(() => chunkText('text', maxSize: -1), throwsArgumentError);
    });

    test('reserves multipart prefix width when part counts gain digits', () {
      final chunks = chunkText('a' * 500, maxSize: 20);

      expect(chunks.length, greaterThanOrEqualTo(10));
      expect(chunks.every((chunk) => chunk.length <= 20), isTrue);
    });
  });

  group('chunkTextSlices', () {
    test('preserves UTF-16 source offsets after trimming boundaries', () {
      final text = '${'a' * 40}\n\n  ${'b' * 40}';

      final slices = chunkTextSlices(text, maxSize: 50);

      expect(slices, hasLength(2));
      expect(slices.first.text, 'a' * 40);
      expect(text.substring(slices.first.start, slices.first.end), slices.first.text);
      expect(slices.last.text, 'b' * 40);
      expect(text.substring(slices.last.start, slices.last.end), slices.last.text);
    });

    test('does not add multipart prefixes', () {
      final slices = chunkTextSlices('a' * 100, maxSize: 40);

      expect(slices, hasLength(3));
      expect(slices.every((slice) => !slice.text.startsWith('(')), isTrue);
    });

    test('does not split UTF-16 surrogate pairs at hard boundaries', () {
      final text = '${'a' * 43}😀${'b' * 20}';

      final slices = chunkTextSlices(text, maxSize: 50);

      expect(slices, hasLength(2));
      expect(slices.first.text, 'a' * 43);
      expect(slices.last.text, '😀${'b' * 20}');
    });

    test('can preserve whitespace across chunk boundaries', () {
      final text = List.filled(12, '  indented  ').join('\n');

      final slices = chunkTextSlices(text, maxSize: 30, preserveBoundaryWhitespace: true);

      expect(slices, hasLength(greaterThan(1)));
      expect(slices.map((slice) => slice.text).join(), text);
    });
  });
}

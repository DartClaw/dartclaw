import 'package:dartclaw_core/src/channel/text_chunking.dart';
import 'package:test/test.dart';

void main() {
  group('chunkNativeChatMarkup', () {
    test('balances long emphasis in every bounded chunk', () {
      final chunks = chunkNativeChatMarkup('*${'a' * 120}*', maxSize: 50);

      expect(chunks, hasLength(greaterThan(1)));
      expect(chunks.every((chunk) => chunk.length <= 50), isTrue);
      expect(chunks.every((chunk) => RegExp(r'^\(\d+/\d+\) \*[^*]+\*$').hasMatch(chunk)), isTrue);
    });

    test('keeps synthetic emphasis markers next to non-whitespace content', () {
      final chunks = chunkNativeChatMarkup('*${List.filled(40, 'word').join(' ')}*', maxSize: 50);

      expect(chunks, hasLength(greaterThan(1)));
      for (final chunk in chunks) {
        final body = chunk.replaceFirst(RegExp(r'^\(\d+/\d+\) '), '');
        expect(body, isNot(startsWith('* ')));
        expect(body, isNot(endsWith(' *')));
      }
    });

    test('closes and reopens fenced code on separate prefix lines', () {
      final source = '```\n${List.filled(12, '  long code line  ').join('\n')}\n```';

      final chunks = chunkNativeChatMarkup(source, maxSize: 50);

      expect(chunks, hasLength(greaterThan(1)));
      expect(chunks.every((chunk) => chunk.length <= 50), isTrue);
      expect(chunks.every((chunk) => RegExp(r'^\(\d+/\d+\)\n```\n[\s\S]*\n```$').hasMatch(chunk)), isTrue);
      expect(chunks.join().split('  long code line  ').length - 1, 12);
    });

    test('keeps native angle-bracket links atomic when they fit', () {
      const label = 'linked words';
      const link = '<https://e.co|$label>';
      final source = '${'a' * 10} $link ${'b' * 20}';

      final chunks = chunkNativeChatMarkup(source, maxSize: 50);

      expect(chunks, hasLength(greaterThan(1)));
      expect(chunks.where((chunk) => chunk.contains(link)), hasLength(1));
      expect(chunks.every((chunk) => chunk.length <= 50), isTrue);
    });

    test('does not treat math operators as formatting markers', () {
      final chunks = chunkNativeChatMarkup('${'plain ' * 20}2*3 = 6', maxSize: 50);

      expect(chunks.join(' '), contains('2*3'));
    });
  });
}

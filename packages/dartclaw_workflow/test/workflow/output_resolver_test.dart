import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

void main() {
  group('OutputResolver', () {
    test('round-trips FileSystemOutput', () {
      const resolver = FileSystemOutput(pathPattern: 'fis/s*.md', listMode: true);

      final decoded = OutputResolver.fromJson(resolver.toJson());

      expect(decoded, isA<FileSystemOutput>());
      final filesystem = decoded as FileSystemOutput;
      expect(filesystem.authoritative, isTrue);
      expect(filesystem.pathPattern, 'fis/s*.md');
      expect(filesystem.listMode, isTrue);
      expect(filesystem.matches('fis/s01-foo.md'), isTrue);
      expect(filesystem.matches('docs/unrelated.md'), isFalse);
    });

    test('double-star directory prefix also matches repository root', () {
      const resolver = FileSystemOutput(pathPattern: '**/prd.md', listMode: false);

      expect(resolver.matches('prd.md'), isTrue);
      expect(resolver.matches('docs/specs/prd.md'), isTrue);
      expect(resolver.matches('docs/specs/prd-draft.md'), isFalse);
    });

    test('round-trips InlineOutput', () {
      const resolver = InlineOutput(schemaKey: 'plan_source');

      final decoded = OutputResolver.fromJson(resolver.toJson());

      expect(decoded, isA<InlineOutput>());
      expect(decoded.authoritative, isFalse);
      expect((decoded as InlineOutput).schemaKey, 'plan_source');
    });

    test('round-trips NarrativeOutput', () {
      const resolver = NarrativeOutput(schemaKey: 'summary');

      final decoded = OutputResolver.fromJson(resolver.toJson());

      expect(decoded, isA<NarrativeOutput>());
      expect(decoded.authoritative, isFalse);
      expect((decoded as NarrativeOutput).schemaKey, 'summary');
    });
  });
}

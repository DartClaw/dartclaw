import 'package:dartclaw_runtime/src/knowledge/wiki_source_read.dart';
import 'package:test/test.dart';

void main() {
  group('presentWikiPage', () {
    test('splits frontmatter and title, and shows only confidence, provenance and last update', () {
      final page = presentWikiPage(
        '---\r\nsources:\r\n  - a\r\nprovenance: hybrid\r\nconfidence: high\r\nlast_updated: "2026-11-04T09:00:00Z"\r\n'
            'extra: x\r\n---\r\n# The Title\r\n\r\nBody.',
        'wiki/the-title.md',
      );

      expect(page.title, 'The Title');
      expect(page.markdown.trim(), 'Body.');
      expect(page.metadata, [
        (label: 'Confidence', value: 'high'),
        (label: 'Provenance', value: 'hybrid'),
        (label: 'Updated', value: '2026-11-04'),
      ]);
    });

    test('a page with no frontmatter or title keeps its text and takes the humanized slug', () {
      final page = presentWikiPage('Just text.', 'wiki/deploy_window-notes.md');

      expect((page.title, page.markdown), ('Deploy window notes', 'Just text.'));
      expect(page.metadata, isEmpty);
    });

    test('non-scalar and blank values are omitted', () {
      final page = presentWikiPage('---\nconfidence: [a, b]\nprovenance: ""\n---\nBody', 'wiki/x.md');

      expect(page.metadata, isEmpty);
    });

    test('an empty title heading falls back to the slug and still leaves the body', () {
      final page = presentWikiPage('# \n\nBody.', 'wiki/some-page.md');

      expect((page.title, page.markdown), ('Some page', 'Body.'));
    });
  });
}

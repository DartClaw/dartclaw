import '../knowledge/wiki_source_read.dart';
import 'layout.dart';
import 'loader.dart';

/// One labelled value in a source page's quiet metadata line.
typedef SourceMetadata = List<({String label, String value})>;

/// Renders one wiki page as a standalone page, without the app shell.
///
/// Served to readers who hold a source link and no session, so it carries no
/// navigation, sidebar or restart banner. The page's markdown is escaped into a
/// `data-markdown` container and rendered client-side, so the raw source never
/// reaches the page as markup.
String wikiSourceViewTemplate({required WikiSourcePage page, String appName = 'DartClaw'}) => _render(
  kind: 'Wiki page',
  title: page.title,
  metadata: page.metadata,
  markdown: page.markdown,
  fact: null,
  appName: appName,
);

/// Renders one knowledge graph fact as a standalone page, without the app shell.
///
/// Takes the displayed fields one by one: the fact's private `source` has no parameter, so it cannot reach the page.
String factSourceViewTemplate({
  required String entity,
  required String predicate,
  required String value,
  required String validFrom,
  String? validTo,
  String? invalidatedAt,
  String appName = 'DartClaw',
}) => _render(
  kind: 'Knowledge graph fact',
  title: entity,
  metadata: [
    (label: 'Valid from', value: validFrom),
    (label: 'Valid to', value: validTo ?? 'ongoing'),
    if (invalidatedAt != null) (label: 'Invalidated', value: invalidatedAt),
  ],
  markdown: null,
  fact: {'predicate': predicate, 'value': value},
  appName: appName,
);

/// The metadata line shared by the standalone page and the shell's wiki view, or
/// null when [metadata] is empty so the caller can omit the element.
String? sourceMetadataHtml(SourceMetadata metadata) => metadata.isEmpty
    ? null
    : templateLoader.trellis.renderFragment(
        templateLoader.source('source_view'),
        fragment: 'sourceMeta',
        context: {
          'metadata': [
            for (final item in metadata) {'label': item.label, 'value': item.value},
          ],
        },
      );

String _render({
  required String kind,
  required String title,
  required SourceMetadata metadata,
  String? markdown,
  Map<String, String>? fact,
  required String appName,
}) {
  final body = templateLoader.trellis.renderFragment(
    templateLoader.source('source_view'),
    fragment: 'sourceView',
    context: {
      'appName': appName,
      'kind': kind,
      'title': title,
      'metaHtml': sourceMetadataHtml(metadata),
      'markdown': markdown,
      'fact': fact,
    },
  );
  return layoutTemplate(title: title, body: body, appName: appName, standalone: true);
}

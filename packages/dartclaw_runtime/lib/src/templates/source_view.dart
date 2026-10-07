import 'layout.dart';
import 'loader.dart';

/// Renders one wiki document as a standalone page, without the app shell.
///
/// Served to readers who hold a source link and no session, so it carries no
/// navigation, sidebar or restart banner. [markdown] is escaped into a
/// `data-markdown` container and rendered client-side, so the raw source never
/// reaches the page as markup.
String wikiSourceViewTemplate({required String title, required String markdown, String appName = 'DartClaw'}) =>
    _render(title: title, markdown: markdown, fact: null, appName: appName);

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
  title: 'Knowledge graph fact',
  markdown: null,
  fact: {
    'entity': entity,
    'predicate': predicate,
    'value': value,
    'validFrom': validFrom,
    'validTo': validTo ?? 'ongoing',
    'invalidatedAt': invalidatedAt,
  },
  appName: appName,
);

String _render({required String title, String? markdown, Map<String, String?>? fact, required String appName}) {
  final body = templateLoader.trellis.render(templateLoader.source('source_view'), {
    'title': title,
    'markdown': markdown,
    'fact': fact,
  });
  return layoutTemplate(title: title, body: body, appName: appName);
}

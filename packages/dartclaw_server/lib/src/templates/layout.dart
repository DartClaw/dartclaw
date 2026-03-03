import 'loader.dart';

/// Full HTML document wrapper. [title] is auto-escaped by Trellis (`tl:text`);
/// [body] is raw HTML inserted verbatim via `tl:utext`.
///
/// Callers should wrap `<main id="main-content" hx-history-elt>` in [body]
/// for HTMX SPA navigation history tracking.
String layoutTemplate({required String title, required String body}) {
  return templateLoader.trellis.render(
    templateLoader.source('layout'),
    {'title': title, 'body': body},
  );
}

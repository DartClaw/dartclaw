import 'loader.dart';

/// Full HTML document wrapper. [title] is auto-escaped by Trellis (`tl:text`);
/// [body] is raw HTML inserted verbatim via `tl:utext`.
///
/// [appName] is the configurable instance name shown in the browser tab title
/// and exposed as `data-app-name` on `<body>` for client-side JS. Defaults to
/// `'DartClaw'`.
///
/// Callers should wrap `<main id="main-content" hx-history-elt>` in [body]
/// for HTMX SPA navigation history tracking.
String layoutTemplate({required String title, required String body, String appName = 'DartClaw'}) {
  return templateLoader.trellis.render(templateLoader.source('layout'), {
    'title': title,
    'body': body,
    'appName': appName,
  });
}

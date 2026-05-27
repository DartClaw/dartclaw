import 'dart:convert';

import 'loader.dart';

const _defaultLayoutScripts = <String>[];

/// Returns the per-page script set appended to [layoutTemplate]'s scripts block.
///
/// Returns an empty list today: the shell scripts (Stimulus bootstrap, vendored libs)
/// are loaded directly from `layout.html`. The seam is kept so a future page can opt
/// into an extra script without re-plumbing every caller.
List<String> standardShellScripts() {
  return <String>[..._defaultLayoutScripts];
}

/// Full HTML document wrapper. [title] is auto-escaped by Trellis (`tl:text`);
/// [body] is raw HTML inserted verbatim via `tl:utext`.
///
/// [appName] is the configurable instance name shown in the browser tab title
/// and exposed as `data-app-name` on `<body>` for client-side JS. Defaults to
/// `'DartClaw'`.
///
/// Callers should wrap `<main id="main-content" hx-history-elt>` in [body]
/// for HTMX SPA navigation history tracking.
String layoutTemplate({
  required String title,
  required String body,
  String appName = 'DartClaw',
  List<String> scripts = _defaultLayoutScripts,
}) {
  final scriptsHtml = _renderScriptTags(scripts);
  return templateLoader.trellis.render(templateLoader.source('layout'), {
    'title': title,
    'body': body,
    'appName': appName,
    'scriptsHtml': scriptsHtml,
  });
}

String _renderScriptTags(List<String> scripts) {
  final escape = const HtmlEscape();
  final uniqueScripts = <String>{};
  final buffer = StringBuffer();
  for (final script in scripts) {
    if (script.isEmpty || !uniqueScripts.add(script)) {
      continue;
    }
    buffer.writeln('<script defer="defer" src="${escape.convert(script)}"></script>');
  }
  return buffer.toString().trimRight();
}

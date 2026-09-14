import 'package:dartclaw_runtime/src/templates/layout.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  test('global palette renders semantic search, filters, live status, and results', () {
    final html = layoutTemplate(title: '<unsafe>', body: '<main id="main-content"></main>');

    expect(html, contains('id="global-command-dialog"'));
    expect(html, contains('aria-labelledby="global-command-title"'));
    expect(html, contains('data-search-lifecycle'));
    expect(html, contains('data-search-project'));
    expect(html, contains('data-command-status="" role="status" aria-live="polite"'));
    expect(html, contains('data-command-results="" role="listbox"'));
    expect(html, contains('<title>&lt;unsafe&gt; - DartClaw</title>'));
  });

  test('current palette is bounded to the conversation and exposes exact result navigation', () {
    final source = templateLoader.source('chat');

    expect(source, contains('data-command-dialog="current"'));
    expect(source, contains('Find in conversation'));
    expect(source, contains('data-command-query="current"'));
    expect(source, contains('data-command-results'));
  });
}

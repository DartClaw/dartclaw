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
    expect(html, contains('aria-label="Search and commands"'));
    // Lifecycle is a row of canon chips now, not a <select>.
    expect(html, contains('data-search-lifecycle="all"'));
    expect(html, contains('class="chip" aria-pressed="true" data-search-lifecycle-option="all"'));
    expect(html, isNot(contains('<select class="form-select" data-search-lifecycle')));
    expect(html, contains('data-search-project'));
    expect(html, contains('class="palette-input-row"'));
    expect(html, contains('data-command-status="" role="status" aria-live="polite"'));
    expect(html, contains('data-command-results="" role="listbox"'));
    expect(html, contains('<title>&lt;unsafe&gt; - DartClaw</title>'));
  });

  test('find in conversation is a slim bar with a count and match stepping', () {
    final source = templateLoader.source('chat');

    expect(source, contains('class="find-bar"'));
    expect(source, contains('Find in conversation'));
    expect(source, contains('data-dc-chat-target="findQuery"'));
    expect(source, contains('data-dc-chat-target="findCount"'));
    expect(source, contains('data-action="dc-chat#findPrevious"'));
    expect(source, contains('data-action="dc-chat#findNext"'));
    expect(source, contains('data-action="dc-chat#closeFind"'));
    // The bar is invoked from the topbar overflow and the palette; it is not a
    // standing control in the message stream.
    expect(source, isNot(contains('class="btn btn-ghost conversation-find"')));
  });
}

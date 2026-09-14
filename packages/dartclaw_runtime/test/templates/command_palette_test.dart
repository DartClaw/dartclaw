import 'package:dartclaw_runtime/src/templates/layout.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:dartclaw_runtime/src/templates/topbar.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  test('every topbar projects the global palette trigger', () {
    for (final topbar in [topbarTemplate(), pageTopbarTemplate(title: 'Settings')]) {
      expect(topbar, contains('data-command-open="global"'));
      expect(topbar, contains('aria-haspopup="dialog"'));
      expect(topbar, contains('<kbd>⌘K</kbd>'));
    }
  });

  test('slash palette is a semantic listbox adjacent to the ordinary composer', () {
    final source = templateLoader.source('chat');

    expect(source, contains('data-slash-palette'));
    expect(source, contains('data-slash-results role="listbox" aria-label="Commands"'));
    expect(source, contains('id="chat-form"'));
    expect(source, contains('name="message"'));
  });

  test('layout installs the single controller authority for both palette surfaces', () {
    final html = layoutTemplate(title: 'Commands', body: '<main id="main-content"></main>');
    expect(html, contains('data-controller="dc-shell dc-toast dc-conversation-command"'));
  });
}

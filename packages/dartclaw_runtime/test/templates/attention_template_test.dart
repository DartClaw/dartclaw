import 'package:dartclaw_runtime/src/templates/topbar.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);
  test('shell topbar exposes persistent accessible attention navigation', () {
    final html = topbarTemplate();
    expect(html, contains('data-attention-toggle'));
    expect(html, contains('aria-expanded="false"'));
    expect(html, contains('data-attention-panel'));
    expect(html, contains('data-attention-next'));
    expect(html, contains('data-session-create="true"'));
  });
}

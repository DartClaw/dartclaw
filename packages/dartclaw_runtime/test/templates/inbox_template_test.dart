import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);
  test('sidebar exposes escaped inbox controls, counts, local drafts and settled paging', () {
    const session = (id: 's-1', title: '<unsafe>', type: SessionType.user, provider: 'claude');
    final html = sidebarTemplate(activeEntries: const [session]);
    expect(html, contains('data-inbox-filters'));
    expect(html, contains('data-next-attention'));
    expect(html, contains('Drafts on this device'));
    expect(html, contains('data-settled-list'));
    expect(html, contains('data-inbox-settle-selected'));
    expect(html, contains('data-inbox-settle'));
    expect(html, contains('data-inbox-clear-filter'));
    expect(html, contains('data-inbox-session-id="s-1"'));
    expect(html, contains('&lt;unsafe&gt;'));
  });
}

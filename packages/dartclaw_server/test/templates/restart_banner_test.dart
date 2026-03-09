import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/restart_banner.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('restartBannerTemplate', () {
    test('with fields renders banner HTML', () {
      final html = restartBannerTemplate(
        pendingFields: ['agent.model', 'port'],
      );

      expect(html, contains('banner-restart'));
      expect(html, contains('agent.model, port'));
      expect(html, contains('Restart Now'));
      expect(html, contains('Dismiss'));
      expect(html, contains('data-action="confirm-restart"'));
      expect(html, contains('data-action="dismiss-restart-banner"'));
    });

    test('with empty fields returns empty string', () {
      final html = restartBannerTemplate(pendingFields: []);

      expect(html, isEmpty);
    });
  });
}

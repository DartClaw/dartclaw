import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:dartclaw_runtime/src/templates/restart_banner.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('restartBannerTemplate', () {
    test('with fields renders banner HTML', () {
      final html = restartBannerTemplate(pendingFields: ['agent.model', 'port']);

      expect(html, contains('banner-restart'));
      expect(html, contains('agent.model, port'));
      expect(html, contains('Restart Now'));
      expect(html, contains('Dismiss'));
      expect(html, isNot(contains('data-dc-legacy-action')));
    });

    test('with fields renders the node live and operable', () {
      final html = restartBannerTemplate(pendingFields: ['agent.model']);

      expect(html, isNot(contains('hidden')));
      expect(html, isNot(contains('inert')));
    });

    test('with empty fields renders the same node dormant', () {
      final html = restartBannerTemplate(pendingFields: []);

      // The slot always holds one stable #restart-banner so client state can
      // reveal and re-hide it without creating or destroying markup.
      expect(html, contains('id="restart-banner"'));
      expect(html, contains('id="restart-banner-fields"'));
      expect(html, contains('hidden=""'));
      // Valueless, never inert="false" — any value at all keeps a node inert.
      expect(html, contains('inert=""'));
      expect(html, isNot(contains('inert="false"')));
      expect(html, contains('<strong id="restart-banner-fields"></strong>'));
    });

    test('the dismiss action stays outside the generic banner sweeper', () {
      final html = restartBannerTemplate(pendingFields: ['port']);

      // The shell removes the closest .banner for any `.dismiss` click, and this
      // node must survive dismissal so a later pending set can reuse it. The
      // class would also pull in canon's `.banner .dismiss { border: none }`.
      expect(html, isNot(contains('dismiss"')));
      expect(html, contains('dc-shell#dismissRestartBanner'));
    });

    test('both actions carry the base .btn class', () {
      final html = restartBannerTemplate(pendingFields: ['port']);

      // .btn-sm supplies only font-size and padding; without .btn the controls
      // fall through to UA buttons in a proportional face.
      expect(RegExp(r'class="btn ').allMatches(html), hasLength(2));
      expect(html, isNot(contains('class="btn-sm')));
    });
  });
}

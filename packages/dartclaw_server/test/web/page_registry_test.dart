import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _StubDashboardPage implements DashboardPage {
  _StubDashboardPage(this._route, this._title, {this.iconValue});

  final String _route;
  final String _title;
  final String? iconValue;

  @override
  String get route => _route;

  @override
  String get title => _title;

  @override
  String get navGroup => 'test';

  @override
  String? get icon => iconValue;

  @override
  Future<Response> handler(Request request, PageContext context) async {
    return Response.ok(_title);
  }
}

class _HiddenStubDashboardPage extends _StubDashboardPage implements DashboardNavigationExclusion {
  _HiddenStubDashboardPage(super._route, super._title);
}

void main() {
  group('PageRegistry', () {
    test('register + resolve returns the registered page', () {
      final registry = PageRegistry();
      final page = _StubDashboardPage('/custom', 'Custom');

      registry.register(page);

      expect(registry.resolve('/custom'), same(page));
    });

    test('navItems preserves registration order and active item', () {
      final registry = PageRegistry()
        ..register(_StubDashboardPage('/health-dashboard', 'Health', iconValue: 'health'))
        ..register(_StubDashboardPage('/custom', 'Custom'));

      final navItems = registry.navItems(activePage: 'Custom');

      expect(navItems, hasLength(2));
      expect(navItems[0].label, 'Health');
      expect(navItems[1].label, 'Custom');
      expect(navItems[0].active, isFalse);
      expect(navItems[1].active, isTrue);
      expect(navItems[0].navGroup, 'test');
      expect(navItems[0].icon, 'health');
      expect(navItems[1].icon, isNull);
    });

    test('registered pages can stay routable without appearing in navigation', () {
      final registry = PageRegistry()
        ..register(_StubDashboardPage('/visible', 'Visible'))
        ..register(_HiddenStubDashboardPage('/nested', 'Nested'));

      expect(registry.resolve('/nested'), isNotNull);
      expect(registry.pages, hasLength(2));
      expect(registry.navItems(activePage: 'Nested').map((item) => item.label), ['Visible']);
    });

    test('register rejects reserved fixed sub-routes and earlier-mounted server paths', () {
      final registry = PageRegistry();
      final reservedRoutes = [
        '/health-dashboard/audit',
        '/settings/channels/whatsapp',
        '/settings/channels/signal',
        '/memory/content',
        '/knowledge/wiki',
        '/knowledge/wiki/custom',
        '/health',
        '/static/app.css',
        '/whatsapp/pairing',
        '/whatsapp/pairing/poll',
        '/signal/link',
        '/login',
        '/sessions',
        '/sessions/custom',
        '/api',
        '/api/custom',
      ];

      for (final route in reservedRoutes) {
        expect(
          () => registry.register(_StubDashboardPage(route, 'Reserved')),
          throwsA(isA<StateError>()),
          reason: route,
        );
      }

      expect(() => registry.register(_StubDashboardPage('/knowledge/wikimedia', 'Allowed')), returnsNormally);
    });

    test('register rejects duplicate routes', () {
      final registry = PageRegistry()..register(_StubDashboardPage('/custom', 'First'));

      expect(() => registry.register(_StubDashboardPage('/custom', 'Second')), throwsA(isA<StateError>()));
    });

    test('register rejects routes without a leading slash', () {
      final registry = PageRegistry();

      expect(() => registry.register(_StubDashboardPage('custom', 'Custom')), throwsA(isA<ArgumentError>()));
    });
  });
}

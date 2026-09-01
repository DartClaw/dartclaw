import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _StubDashboardPage implements DashboardPage {
  new(this._route, this._title, {this.iconValue, this.extraRoutes = const []});

  final String _route;
  final String _title;
  final String? iconValue;
  final List<PageRouteDeclaration> extraRoutes;

  @override
  String get route => _route;

  @override
  List<PageRouteDeclaration> get declaredRoutes => extraRoutes;

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
  new(super._route, super._title);
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

  group('declared routes', () {
    test('a declaration shadowed by a hand-registered route is refused, not silently shadowed', () {
      // shelf_router answers with the first matching handler, so a page
      // declaring one of these would register cleanly and never be reached.
      const shadowed = [(method: 'POST', path: '/settings'), (method: 'POST', path: '/pairing/code')];

      for (final route in shadowed) {
        expect(
          () => PageRegistry()
            ..register(
              _StubDashboardPage(
                '/decl-${route.path.hashCode}',
                'Decl',
                extraRoutes: [(method: route.method, path: route.path)],
              ),
            ),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('reserved route pattern'))),
          reason: '${route.method} ${route.path} is hand-registered and must not be declarable',
        );
      }
    });

    test('the page halves of those paths stay registrable', () {
      // Only the hand-registered method and sub-path are reserved: `/settings`,
      // `/tasks` and `/workflows` are pages in their own right.
      expect(() => PageRegistry()..register(_StubDashboardPage('/settings', 'Settings')), returnsNormally);
      expect(() => PageRegistry()..register(_StubDashboardPage('/tasks', 'Tasks')), returnsNormally);
      expect(() => PageRegistry()..register(_StubDashboardPage('/workflows', 'Workflows')), returnsNormally);
    });

    test('task and workflow pages can own their parameterized routes', () {
      expect(
        () => PageRegistry()
          ..register(
            _StubDashboardPage(
              '/tasks',
              'Tasks',
              extraRoutes: const [(method: 'GET', path: '/tasks/<id>'), (method: 'POST', path: '/tasks/<id>/start')],
            ),
          )
          ..register(
            _StubDashboardPage(
              '/workflows',
              'Workflows',
              extraRoutes: const [
                (method: 'GET', path: '/workflows/<runId>'),
                (method: 'GET', path: '/workflows/<runId>/steps/<stepIndex>'),
              ],
            ),
          ),
        returnsNormally,
      );
    });

    test('a declared route under a reserved pattern is refused, naming the pattern', () {
      final registry = PageRegistry();
      final page = _StubDashboardPage(
        '/custom',
        'Custom',
        extraRoutes: const [(method: 'POST', path: '/api/custom/save')],
      );

      expect(
        () => registry.register(page),
        throwsA(isA<StateError>().having((e) => e.message, 'message', allOf(contains('/api'), contains('reserved')))),
      );
      expect(registry.resolve('/custom'), isNull, reason: 'a refused registration must leave nothing behind');
    });

    test('a declared route without a leading slash is refused', () {
      final registry = PageRegistry();
      final page = _StubDashboardPage('/custom', 'Custom', extraRoutes: const [(method: 'POST', path: 'save')]);

      expect(() => registry.register(page), throwsA(isA<ArgumentError>()));
    });

    test('two pages declaring the same method and path collide at registration', () {
      final registry = PageRegistry()
        ..register(_StubDashboardPage('/first', 'First', extraRoutes: const [(method: 'POST', path: '/shared/act')]));

      expect(
        () => registry.register(
          _StubDashboardPage('/second', 'Second', extraRoutes: const [(method: 'POST', path: '/shared/act')]),
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('POST /shared/act'))),
      );
    });

    test('a page declaring a GET another page already serves as its route collides', () {
      final registry = PageRegistry()..register(_StubDashboardPage('/tasks', 'Tasks'));

      expect(
        () => registry.register(
          _StubDashboardPage('/other', 'Other', extraRoutes: const [(method: 'GET', path: '/tasks')]),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('one page declaring the same path twice for one method collides with itself', () {
      final registry = PageRegistry();

      expect(
        () => registry.register(
          _StubDashboardPage(
            '/custom',
            'Custom',
            extraRoutes: const [(method: 'POST', path: '/custom/act'), (method: 'post', path: '/custom/act')],
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('two pages declaring the same matcher under different parameter names collide', () {
      // `/shared/<id>/act` and `/shared/<other>/act` compile to one shelf_router
      // matcher, so the second would register cleanly and never be reached.
      final registry = PageRegistry()
        ..register(
          _StubDashboardPage('/first', 'First', extraRoutes: const [(method: 'POST', path: '/shared/<id>/act')]),
        );

      expect(
        () => registry.register(
          _StubDashboardPage('/second', 'Second', extraRoutes: const [(method: 'POST', path: '/shared/<other>/act')]),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('a parameter regex still distinguishes two declarations', () {
      final registry = PageRegistry()
        ..register(_StubDashboardPage('/first', 'First', extraRoutes: const [(method: 'GET', path: '/shared/<id>')]));

      expect(
        () => registry.register(
          _StubDashboardPage('/second', 'Second', extraRoutes: const [(method: 'GET', path: r'/shared/<rest|.*>')]),
        ),
        returnsNormally,
      );
    });

    test('the same path declared for two different methods registers cleanly', () {
      final registry = PageRegistry();

      expect(
        () => registry.register(
          _StubDashboardPage(
            '/custom',
            'Custom',
            extraRoutes: const [(method: 'POST', path: '/custom/item'), (method: 'DELETE', path: '/custom/item')],
          ),
        ),
        returnsNormally,
      );
    });

    test('a page declares no extra routes by default', () {
      expect(_StubDashboardPage('/custom', 'Custom').declaredRoutes, isEmpty);
    });
  });
}

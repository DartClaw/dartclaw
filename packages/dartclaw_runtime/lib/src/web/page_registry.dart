import 'dart:collection';

import '../templates/sidebar.dart';
import 'dashboard_page.dart';

/// Ordered registry of dashboard pages.
class PageRegistry {
  final LinkedHashMap<String, DashboardPage> _pages = LinkedHashMap();

  /// Every `METHOD path` this registry has handed out, so a page route and the
  /// declared routes beside it are validated as one surface.
  final Set<String> _claims = {};

  /// Registers [page] with its page `GET` and every declared route.
  ///
  /// Throws before mutating any state when a path is malformed, matches a
  /// reserved pattern, or repeats a method-and-path another page (or this one)
  /// already claims. Registration happens at startup, so a collision is fatal
  /// rather than a request-time surprise.
  void register(DashboardPage page) {
    _validatePath(page.route, method: 'GET');
    if (_pages.containsKey(page.route)) {
      throw StateError('Page already registered for route: ${page.route}');
    }

    final claims = <String>{};
    void claim(String method, String path) {
      final key = '$method ${_canonicalPath(path)}';
      if (_claims.contains(key) || !claims.add(key)) {
        throw StateError('Route already registered: $method $path');
      }
    }

    claim('GET', page.route);
    for (final declared in page.declaredRoutes) {
      final method = declared.method.toUpperCase();
      _validatePath(declared.path, method: method);
      claim(method, declared.path);
    }

    _pages[page.route] = page;
    _claims.addAll(claims);
  }

  /// Drops the parameter *names* from a `shelf_router` pattern.
  ///
  /// `/x/<id>/y` and `/x/<other>/y` compile to the same matcher, so two pages
  /// declaring them claim one route under different spellings. Any regex a
  /// parameter carries is kept, since it is what makes two patterns differ.
  static String _canonicalPath(String path) =>
      path.replaceAllMapped(RegExp(r'<([^>|]*)(\|[^>]*)?>'), (m) => '<${m[2] ?? ''}>');

  static void _validatePath(String path, {required String method}) {
    if (!path.startsWith('/')) {
      throw ArgumentError('Route must start with /: $path');
    }
    final reservedMatch = _matchReservedRoute(path, method);
    if (reservedMatch != null) {
      throw StateError('Page route conflicts with reserved route pattern $reservedMatch: $path');
    }
  }

  DashboardPage? resolve(String route) => _pages[route];

  List<DashboardPage> get pages => List.unmodifiable(_pages.values);

  List<NavItem> navItems({required String activePage}) {
    return [
      for (final page in _pages.values)
        if (page is! DashboardNavigationExclusion)
          (
            label: page.title,
            href: page.route,
            active: page.title == activePage,
            navGroup: page.navGroup,
            icon: page.icon,
          ),
    ];
  }
}

typedef _RouteMatcher = bool Function(String route);

/// Routes `web_routes.dart` and the channel pairing routers register by hand.
///
/// `method: null` reserves every method. A method-scoped row exists where the
/// path is legitimately a page's own: `GET /settings` is the settings page,
/// while `POST /settings` is hand-registered, and a page declaring the latter
/// would register cleanly and never be reached - shelf_router answers with the
/// first matching handler, so the shadowed declaration fails silently.
final _reservedRoutePatterns = <({String label, String? method, _RouteMatcher matches})>[
  (label: 'POST /settings', method: 'POST', matches: (route) => route == '/settings'),
  (label: 'POST /pairing/code', method: 'POST', matches: (route) => route == '/pairing/code'),
  (label: 'POST /pairing/disconnect', method: 'POST', matches: (route) => route == '/pairing/disconnect'),
  (
    label: '/health-dashboard/audit',
    method: null,
    matches: (route) => _matchesReservedPath(route, '/health-dashboard/audit'),
  ),
  (label: '/memory/content', method: null, matches: (route) => _matchesReservedPath(route, '/memory/content')),
  (label: '/knowledge/wiki', method: null, matches: (route) => _matchesReservedPath(route, '/knowledge/wiki')),
  (label: '/health', method: null, matches: (route) => route == '/health'),
  (label: '/static/', method: null, matches: (route) => _matchesReservedPrefixOnly(route, '/static/')),
  (label: '/whatsapp/', method: null, matches: (route) => _matchesReservedPrefixOnly(route, '/whatsapp/')),
  (label: '/signal/', method: null, matches: (route) => _matchesReservedPrefixOnly(route, '/signal/')),
  (label: '/login', method: null, matches: (route) => _matchesReservedPath(route, '/login')),
  (label: '/sessions', method: null, matches: (route) => _matchesReservedPrefix(route, '/sessions')),
  (label: '/api', method: null, matches: (route) => _matchesReservedPrefix(route, '/api')),
];

bool _matchesReservedPath(String route, String reservedPath) {
  return route == reservedPath || route.startsWith('$reservedPath/');
}

bool _matchesReservedPrefix(String route, String reservedPrefix) {
  return route == reservedPrefix || route.startsWith('$reservedPrefix/');
}

bool _matchesReservedPrefixOnly(String route, String reservedPrefix) {
  return route.startsWith(reservedPrefix);
}

String? _matchReservedRoute(String route, String method) {
  for (final pattern in _reservedRoutePatterns) {
    if (pattern.method != null && pattern.method != method) continue;
    if (pattern.matches(route)) {
      return pattern.label;
    }
  }
  return null;
}

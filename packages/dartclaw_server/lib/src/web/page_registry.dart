import 'dart:collection';

import '../templates/sidebar.dart';
import 'dashboard_page.dart';

/// Ordered registry of dashboard pages.
class PageRegistry {
  final LinkedHashMap<String, DashboardPage> _pages = LinkedHashMap();

  void register(DashboardPage page) {
    if (!page.route.startsWith('/')) {
      throw ArgumentError('Route must start with /: ${page.route}');
    }
    final reservedMatch = _matchReservedRoute(page.route);
    if (reservedMatch != null) {
      throw StateError('Page route conflicts with reserved route pattern $reservedMatch: ${page.route}');
    }
    if (_pages.containsKey(page.route)) {
      throw StateError('Page already registered for route: ${page.route}');
    }
    _pages[page.route] = page;
  }

  DashboardPage? resolve(String route) => _pages[route];

  List<DashboardPage> get pages => List.unmodifiable(_pages.values);

  List<NavItem> navItems({required String activePage}) {
    return [
      for (final page in _pages.values)
        (label: page.title, href: page.route, active: page.title == activePage, navGroup: page.navGroup),
    ];
  }
}

typedef _RouteMatcher = bool Function(String route);

final _reservedRoutePatterns = <({String label, _RouteMatcher matches})>[
  (label: '/health-dashboard/audit', matches: (route) => _matchesReservedPath(route, '/health-dashboard/audit')),
  (
    label: '/settings/channels/whatsapp',
    matches: (route) => _matchesReservedPath(route, '/settings/channels/whatsapp'),
  ),
  (label: '/settings/channels/signal', matches: (route) => _matchesReservedPath(route, '/settings/channels/signal')),
  (
    label: '/settings/channels/google_chat',
    matches: (route) => _matchesReservedPath(route, '/settings/channels/google_chat'),
  ),
  (label: '/memory/content', matches: (route) => _matchesReservedPath(route, '/memory/content')),
  (label: '/health', matches: (route) => route == '/health'),
  (label: '/static/', matches: (route) => _matchesReservedPrefixOnly(route, '/static/')),
  (label: '/whatsapp/', matches: (route) => _matchesReservedPrefixOnly(route, '/whatsapp/')),
  (label: '/signal/', matches: (route) => _matchesReservedPrefixOnly(route, '/signal/')),
  (label: '/login', matches: (route) => _matchesReservedPath(route, '/login')),
  (label: '/sessions', matches: (route) => _matchesReservedPrefix(route, '/sessions')),
  (label: '/api', matches: (route) => _matchesReservedPrefix(route, '/api')),
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

String? _matchReservedRoute(String route) {
  for (final pattern in _reservedRoutePatterns) {
    if (pattern.matches(route)) {
      return pattern.label;
    }
  }
  return null;
}

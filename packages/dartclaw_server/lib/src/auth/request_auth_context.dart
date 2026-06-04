import 'package:shelf/shelf.dart';

const dartclawAuthIsAdminContextKey = 'dartclaw.auth.isAdmin';
const dartclawAuthIsCookieContextKey = 'dartclaw.auth.isCookie';

Request withAdminAuthContext(Request request) {
  return request.change(context: {...request.context, dartclawAuthIsAdminContextKey: true});
}

Request withCookieAuthContext(Request request) {
  return request.change(
    context: {...request.context, dartclawAuthIsAdminContextKey: true, dartclawAuthIsCookieContextKey: true},
  );
}

bool requestHasAdminAccess(Request request) {
  final value = request.context[dartclawAuthIsAdminContextKey];
  if (value is bool) {
    return value;
  }
  return false;
}

/// Returns true when the request was authenticated via a session cookie (as
/// opposed to a Bearer token). Used by the Origin/Host guard to scope CSRF
/// checks to browser sessions only.
bool requestIsCookieAuthenticated(Request request) {
  final value = request.context[dartclawAuthIsCookieContextKey];
  return value is bool && value;
}

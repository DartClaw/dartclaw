import 'package:shelf/shelf.dart';

/// Whether the request is an HTMX SPA navigation that expects a fragment
/// (not a history-restore which needs the full page).
bool wantsFragment(Request request) {
  final isHx = request.headers['HX-Request'] == 'true';
  final isHistoryRestore = request.headers['HX-History-Restore-Request'] == 'true';
  return isHx && !isHistoryRestore;
}

/// Returns an HTML fragment response (used for SPA partial swaps).
Response htmlFragment(String html) => Response.ok(html, headers: {'content-type': 'text/html; charset=utf-8'});

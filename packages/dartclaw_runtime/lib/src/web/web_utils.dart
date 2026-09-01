import 'dart:convert';

import 'package:shelf/shelf.dart';

/// Default HTTP response headers for HTML fragment and page bodies.
const htmlHeaders = {'content-type': 'text/html; charset=utf-8'};

/// Header asking the browser to raise a toast once the swap has settled.
///
/// `dc_toast_controller.js` listens for `dc:toast` on `document.body`, and HTMX
/// redirects the trigger there when the element that sent the request left the
/// document — which is what a mutation swapping its own form away does. The
/// payload is escaped to ASCII because a header carrying a non-Latin-1 message
/// would be mangled on the wire.
Map<String, String> toastTriggerHeader(String type, String message) => {
  'HX-Trigger-After-Swap': _asciiJson({
    'dc:toast': {'type': type, 'message': message},
  }),
};

String _asciiJson(Object value) {
  final buffer = StringBuffer();
  for (final unit in jsonEncode(value).codeUnits) {
    if (unit < 0x20 || unit > 0x7e) {
      buffer.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
    } else {
      buffer.writeCharCode(unit);
    }
  }
  return buffer.toString();
}

/// Whether the request is an HTMX SPA navigation that expects a fragment
/// (not a history-restore which needs the full page).
bool wantsFragment(Request request) {
  final isHx = request.headers['HX-Request'] == 'true';
  final isHistoryRestore = request.headers['HX-History-Restore-Request'] == 'true';
  return isHx && !isHistoryRestore;
}

/// Returns an HTML fragment response (used for SPA partial swaps).
Response htmlFragment(String html) => Response.ok(html, headers: htmlHeaders);

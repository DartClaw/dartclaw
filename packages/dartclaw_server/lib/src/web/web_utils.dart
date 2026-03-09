import 'package:shelf/shelf.dart';

const htmlHeaders = {'content-type': 'text/html; charset=utf-8'};

/// Whether the request is an HTMX SPA navigation that expects a fragment
/// (not a history-restore which needs the full page).
bool wantsFragment(Request request) {
  final isHx = request.headers['HX-Request'] == 'true';
  final isHistoryRestore = request.headers['HX-History-Restore-Request'] == 'true';
  return isHx && !isHistoryRestore;
}

/// Returns an HTML fragment response (used for SPA partial swaps).
Response htmlFragment(String html) => Response.ok(html, headers: htmlHeaders);

/// Extracts a clean E.164-style phone number from a WhatsApp JID.
///
/// e.g. `"12345678901:3@s.whatsapp.net"` → `"+12345678901"`
/// Returns null for non-numeric values (e.g. GOWA device UUIDs).
String? jidToPhone(String? jid) {
  if (jid == null) return null;
  final number = jid.split('@').first.split(':').first;
  if (!RegExp(r'^\d+$').hasMatch(number)) return null;
  return '+$number';
}

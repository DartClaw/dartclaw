import 'package:dartclaw_core/dartclaw_core.dart';

import '../audit/audit_log_reader.dart';

/// Renders the guard audit table HTML fragment.
///
/// Used both for initial health dashboard render (inline) and for
/// HTMX polling updates (`GET /health-dashboard/audit`).
String auditTableFragment({
  required AuditPage auditPage,
  String? verdictFilter,
  String? guardFilter,
}) {
  final buf = StringBuffer();

  // Build the hx-get URL with current filters for polling.
  final baseUrl = '/health-dashboard/audit';
  final queryParams = <String>[];
  if (verdictFilter != null) queryParams.add('verdict=$verdictFilter');
  if (guardFilter != null) queryParams.add('guard=$guardFilter');
  final pollUrl = queryParams.isEmpty ? baseUrl : '$baseUrl?${queryParams.join('&')}';

  buf.write('<div id="audit-table-container" '
      'hx-get="$pollUrl" hx-trigger="every 30s" hx-swap="outerHTML">');

  // Filter toolbar
  buf.write('<div class="table-toolbar">');
  _filterBtn(buf, 'All', null, guardFilter, verdictFilter, isGuard: true);
  for (final g in ['Command', 'File', 'Network', 'Input', 'Content']) {
    _filterBtn(buf, g, g.toLowerCase(), guardFilter, verdictFilter, isGuard: true);
  }
  buf.write('<span style="margin-left:auto"></span>');
  for (final v in ['pass', 'warn', 'block']) {
    _filterBtn(buf, v[0].toUpperCase() + v.substring(1), v, guardFilter, verdictFilter, isGuard: false);
  }
  buf.write('</div>');

  if (auditPage.entries.isEmpty) {
    buf.write('<div class="empty-state" style="padding:var(--sp-6);text-align:center;'
        'color:var(--fg-overlay)">No guard events recorded yet</div>');
  } else {
    // Table
    buf.write('<div class="table-scroll"><table>'
        '<caption class="sr-only">Guard audit log entries</caption>'
        '<thead><tr>'
        '<th>Timestamp</th><th>Guard</th><th>Verdict</th><th>Detail</th>'
        '</tr></thead><tbody>');

    for (final entry in auditPage.entries) {
      _renderRow(buf, entry);
    }

    buf.write('</tbody></table></div>');

    // Pagination
    _renderPagination(buf, auditPage, verdictFilter, guardFilter);
  }

  buf.write('</div>');
  return buf.toString();
}

void _filterBtn(
  StringBuffer buf,
  String label,
  String? value,
  String? currentGuard,
  String? currentVerdict, {
  required bool isGuard,
}) {
  final isActive = isGuard
      ? (value == null ? currentGuard == null : currentGuard == value)
      : currentVerdict == value;

  final params = <String>[];
  if (isGuard) {
    if (value != null) params.add('guard=$value');
    if (currentVerdict != null) params.add('verdict=$currentVerdict');
  } else {
    if (currentGuard != null) params.add('guard=$currentGuard');
    if (value != null && !isActive) params.add('verdict=$value');
    // If clicking active verdict, remove it (toggle off)
  }
  final url = params.isEmpty ? '/health-dashboard/audit' : '/health-dashboard/audit?${params.join('&')}';

  buf.write('<button class="filter-btn${isActive ? ' active' : ''}" '
      'aria-pressed="${isActive ? 'true' : 'false'}" '
      'hx-get="$url" hx-target="#audit-table-container" hx-swap="outerHTML">'
      '${_esc(label)}</button>');
}

void _renderRow(StringBuffer buf, AuditEntry entry) {
  final ts = _formatTimestamp(entry.timestamp);
  final verdictClass = 'verdict-${entry.verdict}';
  final verdictLabel = entry.verdict.toUpperCase();
  final detail = _esc(entry.reason ?? entry.hook);

  buf.write('<tr class="audit-row" tabindex="0" role="button" aria-expanded="false"><td>$ts</td>'
      '<td><span class="guard-type">${_esc(entry.guard)}</span></td>'
      '<td class="$verdictClass">$verdictLabel</td>'
      '<td>$detail</td></tr>');

  // Expandable detail row
  final hasDetail = entry.sessionId != null || entry.channel != null || entry.reason != null;
  if (hasDetail) {
    buf.write('<tr class="audit-detail-row" style="display:none"><td colspan="4">'
        '<div class="audit-detail"><div class="detail-grid">');
    buf.write('<div><span class="detail-label">Hook</span> '
        '<span>${_esc(entry.hook)}</span></div>');
    buf.write('<div><span class="detail-label">Session</span> '
        '<span>${_esc(entry.sessionId ?? '\u2014')}</span></div>');
    buf.write('<div><span class="detail-label">Channel</span> '
        '<span>${_esc(entry.channel ?? '\u2014')}</span></div>');
    buf.write('<div><span class="detail-label">Peer</span> '
        '<span>${_esc(entry.peerId ?? '\u2014')}</span></div>');
    buf.write('</div>');
    if (entry.reason != null) {
      buf.write('<div class="detail-reason"><span class="detail-label">Full Reason</span>'
          '<pre>${_esc(entry.reason!)}</pre></div>');
    }
    buf.write('</div></td></tr>');
  }
}

void _renderPagination(
  StringBuffer buf,
  AuditPage page,
  String? verdictFilter,
  String? guardFilter,
) {
  final start = (page.currentPage - 1) * page.pageSize + 1;
  final end = start + page.entries.length - 1;

  buf.write('<div class="pagination">');
  buf.write('<span class="pagination-info">Showing $start\u2013$end of ${page.totalEntries} events</span>');
  buf.write('<div class="pagination-controls">');

  final baseParams = <String>[];
  if (verdictFilter != null) baseParams.add('verdict=$verdictFilter');
  if (guardFilter != null) baseParams.add('guard=$guardFilter');

  // Previous button
  if (page.currentPage > 1) {
    final prevParams = [...baseParams, 'page=${page.currentPage - 1}'];
    buf.write('<button class="btn btn-ghost btn-sm" '
        'hx-get="/health-dashboard/audit?${prevParams.join('&')}" '
        'hx-target="#audit-table-container" hx-swap="outerHTML">'
        '\u2190 Previous</button>');
  } else {
    buf.write('<button class="btn btn-ghost btn-sm" disabled>\u2190 Previous</button>');
  }

  buf.write('<span class="pagination-page">Page ${page.currentPage} of ${page.totalPages}</span>');

  // Next button
  if (page.currentPage < page.totalPages) {
    final nextParams = [...baseParams, 'page=${page.currentPage + 1}'];
    buf.write('<button class="btn btn-ghost btn-sm" '
        'hx-get="/health-dashboard/audit?${nextParams.join('&')}" '
        'hx-target="#audit-table-container" hx-swap="outerHTML">'
        'Next \u2192</button>');
  } else {
    buf.write('<button class="btn btn-ghost btn-sm" disabled>Next \u2192</button>');
  }

  buf.write('</div></div>');
}

String _formatTimestamp(DateTime dt) {
  final now = DateTime.now();
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  final s = dt.second.toString().padLeft(2, '0');

  if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
    return '$h:$m:$s';
  }

  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[dt.month - 1]} ${dt.day.toString().padLeft(2, '0')} $h:$m';
}

String _esc(String text) {
  return text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';

import '../audit/audit_log_reader.dart';
import 'components.dart';
import 'helpers.dart';

/// Renders the guard audit table HTML fragment.
///
/// Used both for initial health dashboard render (inline) and for
/// HTMX polling updates (`GET /health-dashboard/audit`).
String auditTableFragment({required AuditPage auditPage, String? verdictFilter, String? guardFilter}) {
  final buf = StringBuffer();

  // The poll re-requests the page the reader is on, not page 1 – a refresh that
  // silently jumps to the first page loses their place every 30 seconds.
  final pollUrl = _auditUrl(
    page: auditPage.currentPage > 1 ? auditPage.currentPage : null,
    verdict: verdictFilter,
    guard: guardFilter,
  );

  // `hx-target` and `hx-select` are inheritable, and this fragment renders
  // inside the health page's refresh wrapper (`hx-target="this"
  // hx-select=".content-inner"`). Both are restated here, for the container and
  // for every control inside it: inherited, the poll replaces the whole
  // dashboard with a table, then selects a `.content-inner` the audit response
  // does not contain – leaving the page blank every 30 seconds.
  buf.write(
    '<div id="audit-table-container" '
    'hx-get="$pollUrl" hx-trigger="every 30s" '
    'hx-target="this" hx-select="#audit-table-container" hx-swap="outerHTML">',
  );

  // Filter toolbar: guard chips on the left, verdict chips on the right.
  buf.write('<div class="table-toolbar"><div class="chip-row">');
  _filterChip(buf, 'All', null, guardFilter, verdictFilter, isGuard: true);
  // Each chip is a case-insensitive substring match on the emitted guard name:
  // `content` -> content-guard, `tool` -> task_tool_filter + ToolPolicyGuard,
  // `egress` -> EgressGuard. A chip matching no emitted name is a dead filter.
  for (final g in ['Command', 'File', 'Network', 'Content', 'Tool', 'Egress']) {
    _filterChip(buf, g, g.toLowerCase(), guardFilter, verdictFilter, isGuard: true);
  }
  buf.write('</div><div class="chip-row">');
  for (final v in ['pass', 'warn', 'block']) {
    _filterChip(buf, v[0].toUpperCase() + v.substring(1), v, guardFilter, verdictFilter, isGuard: false);
  }
  buf.write('</div></div>');

  if (auditPage.entries.isEmpty) {
    // An empty page under a filter means "nothing matched", not "nothing
    // happened" – telling an operator who filtered by Block that no guard
    // events exist misreports the state of the system they are checking.
    final filtered = verdictFilter != null || guardFilter != null;
    buf.write(
      emptyStateTemplate(
        title: 'Guard audit log',
        body: filtered ? 'No guard events match the current filters' : 'No guard events recorded yet',
      ),
    );
  } else {
    buf.write(
      '<div class="table-scroll"><table class="data-table">'
      '<caption class="sr-only">Guard audit log entries</caption>'
      '<thead><tr>'
      '<th>Timestamp</th><th>Guard</th><th>Verdict</th><th>Detail</th>'
      '</tr></thead><tbody>',
    );

    for (var i = 0; i < auditPage.entries.length; i++) {
      _renderRow(buf, auditPage.entries[i], i);
    }

    buf.write('</tbody></table></div>');

    _renderPagination(buf, auditPage, verdictFilter, guardFilter);
  }

  buf.write('</div>');
  return buf.toString();
}

/// Builds an audit URL for an `hx-get` attribute.
///
/// `verdict` and `guard` arrive straight from the query string, so they are
/// percent-encoded as query components and then HTML-escaped: unescaped, a
/// crafted `?guard=` value closes the attribute and injects further htmx
/// attributes into the operator's authenticated page, where an `hx-trigger`
/// earlier in the tag wins over the one this fragment intends.
String _auditUrl({int? page, String? verdict, String? guard}) {
  final params = <String>[
    if (guard != null) 'guard=${Uri.encodeQueryComponent(guard)}',
    if (verdict != null) 'verdict=${Uri.encodeQueryComponent(verdict)}',
    if (page != null) 'page=$page',
  ];
  final url = params.isEmpty ? '/health-dashboard/audit' : '/health-dashboard/audit?${params.join('&')}';
  return _esc(url);
}

void _filterChip(
  StringBuffer buf,
  String label,
  String? value,
  String? currentGuard,
  String? currentVerdict, {
  required bool isGuard,
}) {
  final isActive = isGuard ? (value == null ? currentGuard == null : currentGuard == value) : currentVerdict == value;

  // Changing a filter restarts at page 1: the reader's page number does not
  // survive a different result set.
  final url = isGuard
      ? _auditUrl(guard: value, verdict: currentVerdict)
      : _auditUrl(guard: currentGuard, verdict: isActive ? null : value);

  buf.write(
    '<button type="button" class="chip" '
    'aria-pressed="${isActive ? 'true' : 'false'}" '
    'hx-get="$url" hx-target="#audit-table-container" hx-swap="outerHTML">'
    '${_esc(label)}</button>',
  );
}

void _renderRow(StringBuffer buf, AuditEntry entry, int rowIndex) {
  final key = auditEntryKey(entry);
  // The log has no row id and does not de-duplicate, so two entries identical
  // in all eight rendered fields share a key. The key is the restore identity;
  // the element id additionally carries the row's position, or the duplicate
  // would make `aria-controls` resolve to the first row's detail for both.
  final detailId = 'audit-detail-$key-$rowIndex';
  final iso = entry.timestamp.toIso8601String();
  final verdictClass = 'verdict-${entry.verdict}';
  final verdictLabel = entry.verdict.toUpperCase();
  final detail = _esc(entry.reason ?? entry.hook);

  // A row whose only detail is its hook discloses nothing: the Detail column
  // already prints the hook for exactly those rows. Such a row gets a spacer in
  // place of the chevron, so the timestamp column stays aligned with the rows
  // that do open.
  final hasDetail = entry.reason != null || entry.sessionId != null || entry.channel != null || entry.peerId != null;

  final disclosure = hasDetail
      ? '<button type="button" class="btn btn-ghost btn-icon-sm audit-row-toggle" data-icon="chevron-right" '
            'aria-label="Show detail" aria-expanded="false" aria-controls="$detailId" data-audit-key="$key"></button>'
      : '<span class="audit-row-toggle-spacer" aria-hidden="true"></span>';

  buf.write(
    '<tr class="audit-row">'
    '<td><div class="audit-row-time">$disclosure'
    '<time datetime="$iso" title="$iso">${_esc(formatRelativeTime(entry.timestamp))}</time>'
    '</div></td>'
    '<td><span class="guard-type">${_esc(entry.guard)}</span></td>'
    '<td class="$verdictClass">$verdictLabel</td>'
    '<td>$detail</td></tr>',
  );

  if (!hasDetail) return;

  buf.write('<tr class="audit-detail-row" id="$detailId" hidden><td colspan="4">');
  buf.write('<div class="audit-detail"><div class="detail-grid">');
  buf.write('<div><span class="detail-label">Hook</span> <span>${_esc(entry.hook)}</span></div>');
  buf.write('<div><span class="detail-label">Session</span> ${_absentableSpan(entry.sessionId)}</div>');
  buf.write('<div><span class="detail-label">Channel</span> ${_absentableSpan(entry.channel)}</div>');
  buf.write('<div><span class="detail-label">Peer</span> ${_absentableSpan(entry.peerId)}</div>');
  buf.write('</div>');
  if (entry.reason != null) {
    buf.write(
      '<div class="detail-reason"><span class="detail-label">Full Reason</span>'
      '<pre>${_esc(entry.reason!)}</pre></div>',
    );
  }
  buf.write('</div></td></tr>');
}

/// A presentation identity for one audit row, stable across polls.
///
/// The audit log has no row id, so the key is derived from every field the row
/// and its detail actually render. The tuple is JSON-encoded before base64 so
/// the encoding is injective: a delimiter-joined key cannot distinguish
/// `['ab', 'c']` from `['a', 'bc']`, and null from `''`, which would let a
/// refresh re-open a different row than the reader opened.
String auditEntryKey(AuditEntry entry) {
  final tuple = <String?>[
    entry.timestamp.toUtc().toIso8601String(),
    entry.guard,
    entry.verdict,
    entry.hook,
    entry.sessionId,
    entry.channel,
    entry.peerId,
    entry.reason,
  ];
  return base64Url.encode(utf8.encode(jsonEncode(tuple))).replaceAll('=', '');
}

void _renderPagination(StringBuffer buf, AuditPage page, String? verdictFilter, String? guardFilter) {
  final start = (page.currentPage - 1) * page.pageSize + 1;
  final end = start + page.entries.length - 1;

  buf.write('<div class="pagination">');
  buf.write('<span class="pagination-info">Showing $start–$end of ${page.totalEntries} events</span>');
  buf.write('<div class="pagination-controls">');

  if (page.currentPage > 1) {
    buf.write(
      '<button class="btn btn-ghost btn-sm" '
      'hx-get="${_auditUrl(page: page.currentPage - 1, verdict: verdictFilter, guard: guardFilter)}" '
      'hx-target="#audit-table-container" hx-swap="outerHTML">'
      '← Previous</button>',
    );
  } else {
    buf.write('<button class="btn btn-ghost btn-sm" disabled>← Previous</button>');
  }

  buf.write('<span class="pagination-page">Page ${page.currentPage} of ${page.totalPages}</span>');

  if (page.currentPage < page.totalPages) {
    buf.write(
      '<button class="btn btn-ghost btn-sm" '
      'hx-get="${_auditUrl(page: page.currentPage + 1, verdict: verdictFilter, guard: guardFilter)}" '
      'hx-target="#audit-table-container" hx-swap="outerHTML">'
      'Next →</button>',
    );
  } else {
    buf.write('<button class="btn btn-ghost btn-sm" disabled>Next →</button>');
  }

  buf.write('</div></div>');
}

/// A value cell that renders canon's `.value-absent` when the field is empty,
/// so a missing id reads as "no value" rather than as a rendering failure.
String _absentableSpan(String? value) {
  final resolved = absentValue(value);
  return resolved.isAbsent ? '<span class="value-absent"></span>' : '<span>${_esc(resolved.value! as String)}</span>';
}

String _esc(String text) {
  return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
}

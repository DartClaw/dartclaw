import 'helpers.dart';
import 'layout.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the session info standalone page.
String sessionInfoTemplate({
  required String sessionId,
  required String sessionTitle,
  required int messageCount,
  required SidebarData sidebarData,
  String? createdAt,
  int? inputTokens,
  int? outputTokens,
}) {
  final displayTitle = sessionTitle.trim().isEmpty ? 'New Session' : sessionTitle;
  final escapedId = htmlEscape(sessionId);
  final escapedTitle = htmlEscape(displayTitle);
  final totalTokens = (inputTokens ?? 0) + (outputTokens ?? 0);

  final inputStr = inputTokens != null ? _formatNumber(inputTokens) : '—';
  final outputStr = outputTokens != null ? _formatNumber(outputTokens) : '—';
  final totalStr = totalTokens > 0 ? _formatNumber(totalTokens) : '—';

  final createdAtDisplay = createdAt != null ? htmlEscape(createdAt) : '—';

  final sidebar = sidebarTemplate(
    mainSession: sidebarData.main,
    channelSessions: sidebarData.channels,
    sessionEntries: sidebarData.entries,
    activeSessionId: sessionId,
  );

  final topbar = pageTopbarTemplate(
    title: 'Session Info',
    backHref: '/sessions/$escapedId',
    backLabel: 'Back to Chat',
  );

  final body = '''
<div class="shell">
  $sidebar
  $topbar
  <main class="info-content">
    <div class="info-inner">

      <div>
        <div class="info-title">$escapedTitle</div>
        <div class="info-subtitle">$escapedId</div>
      </div>

      <div>
        <h2 class="section-label">Token Usage</h2>
        <div class="token-grid">
          <div class="token-stat">
            <div class="token-stat-label">Input</div>
            <div class="token-stat-value">$inputStr</div>
          </div>
          <div class="token-stat">
            <div class="token-stat-label">Output</div>
            <div class="token-stat-value">$outputStr</div>
          </div>
          <div class="token-stat total">
            <div>
              <div class="token-stat-label">Total</div>
              <div class="token-stat-value">$totalStr</div>
            </div>
          </div>
        </div>
      </div>

      <div>
        <h2 class="section-label">Session Details</h2>
        <div class="meta-row">
          <span class="meta-label">Messages</span>
          <span class="meta-value">$messageCount</span>
        </div>
        <div class="meta-row">
          <span class="meta-label">Created</span>
          <span class="meta-value">$createdAtDisplay</span>
        </div>
        <div class="meta-row">
          <span class="meta-label">Session ID</span>
          <span class="meta-value meta-value-mono">$escapedId</span>
        </div>
      </div>

    </div>
  </main>
</div>''';

  return layoutTemplate(title: 'Session Info', body: body);
}

String _formatNumber(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return n.toString();
}

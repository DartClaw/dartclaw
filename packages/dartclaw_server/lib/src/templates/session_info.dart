import 'helpers.dart';
import 'layout.dart';
import 'sidebar.dart';

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

  final topbar = '''
<header class="topbar">
  <button class="btn btn-icon btn-ghost menu-toggle" aria-label="Open sidebar">&#9776;</button>
  <span class="session-title-static">Session Info</span>
  <div class="topbar-actions">
    <a href="/sessions/$escapedId" class="btn btn-ghost" style="font-size:var(--text-sm);">&larr; Back to Chat</a>
    <button class="theme-toggle" aria-label="Toggle theme"></button>
  </div>
</header>''';

  final body = '''
<style>
  .info-content { overflow-y: auto; padding: var(--sp-6); }
  @media (max-width: 768px) { .info-content { padding: var(--sp-4); } }
  .info-inner { max-width: 640px; margin: 0 auto; display: flex; flex-direction: column; gap: var(--sp-5); }
  .info-title { font-size: var(--text-xl); font-weight: var(--weight-bold); color: var(--fg); margin-bottom: var(--sp-1); }
  .info-subtitle { font-size: var(--text-xs); color: var(--fg-overlay); font-family: var(--font-mono); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .token-grid { display: grid; grid-template-columns: 1fr 1fr; gap: var(--sp-3); }
  .token-stat { background: var(--bg-base); border-radius: var(--radius); padding: var(--sp-3) var(--sp-4); border: var(--border); }
  .token-stat.total { grid-column: 1 / -1; display: flex; align-items: center; justify-content: space-between; }
  .token-stat-label { font-size: var(--text-xs); color: var(--fg-sub0); margin-bottom: var(--sp-1); }
  .token-stat-value { font-size: var(--text-lg); font-weight: var(--weight-bold); color: var(--fg); }
  .token-stat.total .token-stat-label, .token-stat.total .token-stat-value { margin-bottom: 0; }
  .meta-row {
    display: flex; align-items: center; justify-content: space-between; gap: var(--sp-2);
    padding: var(--sp-2) 0; border-bottom: 1px solid color-mix(in srgb, var(--bg-surface0) 50%, transparent);
  }
  .meta-row:last-child { border-bottom: none; }
  .meta-label { font-size: var(--text-sm); color: var(--fg-sub0); flex-shrink: 0; }
  .meta-value { font-size: var(--text-sm); color: var(--fg); text-align: right; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .meta-value-mono { font-family: var(--font-mono); font-size: var(--text-xs); }
</style>
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

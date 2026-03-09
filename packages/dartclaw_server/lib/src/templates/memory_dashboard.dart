import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the full memory dashboard page.
String memoryDashboardTemplate({
  required Map<String, dynamic> status,
  required SidebarData sidebarData,
  required String workspacePath,
  String bannerHtml = '',
  String appName = 'DartClaw',
}) {
  final navItems = buildSystemNavItems(activePage: 'Memory');

  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);

  final topbar = pageTopbarTemplate(title: 'Memory Dashboard', backHref: '/', backLabel: 'Back to Chat');

  final context = _buildContext(status, sidebar, topbar, workspacePath);
  if (bannerHtml.isNotEmpty) context['bannerHtml'] = bannerHtml;

  final body = templateLoader.trellis.render(templateLoader.source('memory_dashboard'), context);
  return layoutTemplate(title: 'Memory', body: body, appName: appName);
}

/// Renders only the inner content for HTMX polling refresh.
///
/// Returns the `#memory-inner` div content without the shell/sidebar/topbar wrapper.
String memoryDashboardContentFragment({
  required Map<String, dynamic> status,
  required String workspacePath,
}) {
  // Re-render the full template but only extract the inner content.
  // Since Trellis renders the whole fragment, we pass minimal sidebar/topbar.
  final context = _buildContext(status, '', '', workspacePath);
  return templateLoader.trellis.render(templateLoader.source('memory_dashboard'), context);
}

Map<String, dynamic> _buildContext(
  Map<String, dynamic> status,
  String sidebar,
  String topbar,
  String workspacePath,
) {
  final memoryMd = status['memoryMd'] as Map<String, dynamic>? ?? {};
  final archiveMd = status['archiveMd'] as Map<String, dynamic>? ?? {};
  final errorsMd = status['errorsMd'] as Map<String, dynamic>? ?? {};
  final learningsMd = status['learningsMd'] as Map<String, dynamic>? ?? {};
  final search = status['search'] as Map<String, dynamic>? ?? {};
  final pruner = status['pruner'] as Map<String, dynamic>? ?? {};
  final dailyLogs = status['dailyLogs'] as Map<String, dynamic>? ?? {};
  final config = status['config'] as Map<String, dynamic>? ?? {};

  // Memory size budget
  final sizeBytes = memoryMd['sizeBytes'] as int? ?? 0;
  final budgetBytes = memoryMd['budgetBytes'] as int? ?? config['memoryMaxBytes'] as int? ?? 32768;
  final budgetPercent = budgetBytes > 0 ? (sizeBytes * 100 / budgetBytes).round() : 0;
  final budgetWarn = budgetPercent >= 80;

  // Pruner status badge
  final prunerStatus = pruner['status'] as String? ?? 'disabled';
  final prunerBadgeClass = switch (prunerStatus) {
    'active' => 'badge-success',
    'overdue' => 'badge-warning',
    'paused' || 'disabled' => 'badge-muted',
    _ => 'badge-muted',
  };

  // Pruner history
  final history = (pruner['history'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  final prunerHistoryRows = history.reversed
      .take(10)
      .map((run) {
        return <String, dynamic>{
          'date': _formatTimestamp(run['timestamp'] as String?),
          'archived': '${run['entriesArchived'] ?? 0}',
          'deduped': '${run['duplicatesRemoved'] ?? 0}',
          'remaining': '${run['entriesRemaining'] ?? 0}',
          'finalSize': formatBytes(run['finalSizeBytes'] as int? ?? 0),
        };
      })
      .toList();

  // Categories
  final categories = (memoryMd['categories'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

  // Daily logs
  final recentLogs = (dailyLogs['recent'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  final logRows = recentLogs
      .map((log) => <String, dynamic>{
            'date': log['date'] as String? ?? '',
            'entries': '${log['entries'] ?? 0}',
            'size': formatBytes(log['sizeBytes'] as int? ?? 0),
          })
      .toList();

  return {
    'sidebar': sidebar,
    'topbar': topbar,
    'workspacePath': workspacePath,
    // Overview
    'memorySizeStr': formatBytes(sizeBytes),
    'budgetStr': formatBytes(budgetBytes),
    'budgetPercent': '$budgetPercent',
    'budgetBarWidth': '$budgetPercent%',
    'budgetWarnClass': budgetWarn ? 'warn' : '',
    'entryCount': '${memoryMd['entryCount'] ?? 0}',
    'archivedCount': '${archiveMd['entryCount'] ?? 0}',
    'errorsCount': '${errorsMd['entryCount'] ?? 0}',
    'errorsCap': '${errorsMd['cap'] ?? 50}',
    'errorsPercent': _fillPercent(errorsMd['entryCount'] as int? ?? 0, errorsMd['cap'] as int? ?? 50),
    'learningsCount': '${learningsMd['entryCount'] ?? 0}',
    'learningsCap': '${learningsMd['cap'] ?? 50}',
    'learningsPercent': _fillPercent(learningsMd['entryCount'] as int? ?? 0, learningsMd['cap'] as int? ?? 50),
    // Pruner
    'prunerStatus': prunerStatus[0].toUpperCase() + prunerStatus.substring(1),
    'prunerBadgeClass': prunerBadgeClass,
    'prunerSchedule': pruner['schedule'] as String? ?? 'N/A',
    'prunerArchiveDays': '${pruner['archiveAfterDays'] ?? 90}',
    'prunerNextRun': _formatTimestamp(pruner['nextRun'] as String?),
    'prunerUndated': '${pruner['undatedCount'] ?? 0}',
    'hasUndated': (pruner['undatedCount'] as int? ?? 0) > 0,
    'hasPrunerHistory': prunerHistoryRows.isNotEmpty,
    'prunerHistory': prunerHistoryRows,
    // Search
    'searchBackend': search['backend'] as String? ?? 'unknown',
    'searchDepth': '${search['depth'] ?? 0}',
    'searchIndexLive': '${search['indexEntries'] ?? 0}',
    'searchIndexArchived': '${search['indexArchived'] ?? 0}',
    'searchIndexTotal': '${(search['indexEntries'] as int? ?? 0) + (search['indexArchived'] as int? ?? 0)}',
    'searchDbSize': formatBytes(search['dbSizeBytes'] as int? ?? 0),
    // Memory files metadata
    'memoryMdEntries': '${memoryMd['entryCount'] ?? 0}',
    'memoryMdSize': formatBytes(memoryMd['sizeBytes'] as int? ?? 0),
    'memoryMdOldest': _formatDate(memoryMd['oldestEntry'] as String?),
    'memoryMdNewest': _formatDate(memoryMd['newestEntry'] as String?),
    'categories': categories
        .map((c) => <String, dynamic>{'name': c['name'] ?? '', 'count': '${c['count'] ?? 0}'})
        .toList(),
    'hasCategories': categories.isNotEmpty,
    'errorsMdSize': formatBytes(errorsMd['sizeBytes'] as int? ?? 0),
    'learningsMdSize': formatBytes(learningsMd['sizeBytes'] as int? ?? 0),
    'archiveMdSize': formatBytes(archiveMd['sizeBytes'] as int? ?? 0),
    'archiveMdEntries': '${archiveMd['entryCount'] ?? 0}',
    // Daily logs
    'logFileCount': '${dailyLogs['fileCount'] ?? 0}',
    'logTotalSize': formatBytes(dailyLogs['totalSizeBytes'] as int? ?? 0),
    'dailyLogs': logRows,
    'hasDailyLogs': logRows.isNotEmpty,
  };
}

String _formatTimestamp(String? iso) {
  if (iso == null) return 'N/A';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

String _formatDate(String? iso) {
  if (iso == null) return 'N/A';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
}

String _fillPercent(int count, int cap) {
  if (cap <= 0) return '0%';
  return '${(count * 100 / cap).round()}%';
}

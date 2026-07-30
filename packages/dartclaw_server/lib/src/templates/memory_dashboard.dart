import 'components.dart';
import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the full memory dashboard page.
String memoryDashboardTemplate({
  required Map<String, dynamic> status,
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  required String workspacePath,
  String restartBannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);

  final topbar = pageTopbarTemplate(title: 'Memory Dashboard', restartBannerHtml: restartBannerHtml);

  final context = _buildContext(status, sidebar, topbar, workspacePath);

  final body = templateLoader.trellis.render(templateLoader.source('memory_dashboard'), context);
  return layoutTemplate(title: 'Memory', body: body, appName: appName, scripts: standardShellScripts());
}

/// Renders only the inner content for HTMX polling refresh.
///
/// Returns the `#memory-inner` div content without the shell/sidebar/topbar wrapper.
String memoryDashboardContentFragment({required Map<String, dynamic> status, required String workspacePath}) {
  // Re-render the full template but only extract the inner content.
  // Since Trellis renders the whole fragment, we pass minimal sidebar/topbar.
  final context = _buildContext(status, '', '', workspacePath);
  return templateLoader.trellis.render(templateLoader.source('memory_dashboard'), context);
}

Map<String, dynamic> _buildContext(Map<String, dynamic> status, String sidebar, String topbar, String workspacePath) {
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
  final budgetOver = budgetPercent > 100;
  final budgetWarn = budgetPercent >= 80;
  // The tile is tinted by how close the workspace is to its budget, never by
  // which metric it is; the cue repeats the threshold in words so the reading
  // survives with colour removed.
  final budgetCue = budgetOver ? 'Over limit' : (budgetWarn ? 'Near limit' : null);

  final errorsCount = errorsMd['entryCount'] as int? ?? 0;
  final learningsCount = learningsMd['entryCount'] as int? ?? 0;
  final errorsPercent = _fillPercent(errorsCount, errorsMd['cap'] as int? ?? 50);
  final learningsPercent = _fillPercent(learningsCount, learningsMd['cap'] as int? ?? 50);

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
  final prunerHistoryRows = history.reversed.take(10).map((run) {
    return <String, dynamic>{
      'date': _formatTimestamp(run['timestamp'] as String?),
      'dateIso': isoTitle(run['timestamp'] as String?),
      'archived': '${run['entriesArchived'] ?? 0}',
      'deduped': '${run['duplicatesRemoved'] ?? 0}',
      'remaining': '${run['entriesRemaining'] ?? 0}',
      'finalSize': formatBytes(run['finalSizeBytes'] as int? ?? 0),
    };
  }).toList();

  // Categories
  final categories = (memoryMd['categories'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

  // Daily logs
  final recentLogs = (dailyLogs['recent'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  final logRows = recentLogs
      .map(
        (log) => <String, dynamic>{
          'date': log['date'] as String? ?? '',
          'entries': '${log['entries'] ?? 0}',
          'size': formatBytes(log['sizeBytes'] as int? ?? 0),
        },
      )
      .toList();

  return {
    'sidebar': sidebar,
    'topbar': topbar,
    'workspacePath': workspacePath,
    'pageHeaderHtml': pageHeaderTemplate(
      subtitle: 'What the agent remembers: size against budget, pruning, the search index and the files themselves.',
    ),
    // Overview
    'memorySizeValue': _byteAmount(sizeBytes),
    'memorySizeUnit': _byteUnit(sizeBytes),
    'memorySizeCardClass': budgetOver ? 'card-metric--error' : (budgetWarn ? 'card-metric--warning' : ''),
    'budgetStr': formatBytes(budgetBytes),
    'budgetPercentLabel': budgetCue == null ? '$budgetPercent%' : '$budgetCue · $budgetPercent%',
    'budgetBarWidth': '$budgetPercent%',
    'budgetWarnClass': budgetOver ? 'meter-fill--error' : (budgetWarn ? 'meter-fill--warning' : ''),
    'budgetMeterEmptyClass': _emptyMeterClass(budgetPercent),
    'entryCount': '${memoryMd['entryCount'] ?? 0}',
    'archivedCount': '${archiveMd['entryCount'] ?? 0}',
    'errorsCount': '$errorsCount',
    'errorsCapLabel': '/ ${errorsMd['cap'] ?? 50}',
    'errorsCardClass': errorsCount > 0 ? 'card-metric--error' : '',
    'errorsPercent': errorsPercent,
    'errorsMeterEmptyClass': _emptyMeterClass(errorsCount),
    'learningsCount': '$learningsCount',
    'learningsCapLabel': '/ ${learningsMd['cap'] ?? 50}',
    'learningsPercent': learningsPercent,
    'learningsMeterEmptyClass': _emptyMeterClass(learningsCount),
    // Pruner
    'prunerStatus': prunerStatus[0].toUpperCase() + prunerStatus.substring(1),
    'prunerBadgeClass': prunerBadgeClass,
    'prunerSchedule': pruner['schedule'] as String?,
    'prunerScheduleAbsent': absentValue(pruner['schedule']).isAbsent,
    'prunerArchiveDays': '${pruner['archiveAfterDays'] ?? 90}',
    'prunerNextRun': _formatTimestamp(pruner['nextRun'] as String?),
    'prunerNextRunIso': isoTitle(pruner['nextRun'] as String?),
    'prunerUndated': '${pruner['undatedCount'] ?? 0}',
    'hasUndated': (pruner['undatedCount'] as int? ?? 0) > 0,
    'hasPrunerHistory': prunerHistoryRows.isNotEmpty,
    'prunerHistory': prunerHistoryRows,
    // Search
    'searchBackend': search['backend'] as String?,
    'searchBackendAbsent': absentValue(search['backend']).isAbsent,
    'searchDepth': '${search['depth'] ?? 0}',
    'searchIndexLive': '${search['indexEntries'] ?? 0}',
    'searchIndexArchived': '${search['indexArchived'] ?? 0}',
    'searchIndexTotal': '${(search['indexEntries'] as int? ?? 0) + (search['indexArchived'] as int? ?? 0)}',
    'searchDbSize': formatBytes(search['dbSizeBytes'] as int? ?? 0),
    // Memory files metadata. Entry counts and MEMORY.md's size are Overview
    // tiles; this card is outside the poll, so a second copy here would freeze
    // at page load while the tile it duplicates kept refreshing.
    'memoryMdOldest': _formatTimestamp(memoryMd['oldestEntry'] as String?),
    'memoryMdOldestIso': isoTitle(memoryMd['oldestEntry'] as String?),
    'memoryMdNewest': _formatTimestamp(memoryMd['newestEntry'] as String?),
    'memoryMdNewestIso': isoTitle(memoryMd['newestEntry'] as String?),
    'categories': categories
        .map((c) => <String, dynamic>{'name': c['name'] ?? '', 'count': '${c['count'] ?? 0}'})
        .toList(),
    'hasCategories': categories.isNotEmpty,
    'errorsMdSize': formatBytes(errorsMd['sizeBytes'] as int? ?? 0),
    'learningsMdSize': formatBytes(learningsMd['sizeBytes'] as int? ?? 0),
    'archiveMdSize': formatBytes(archiveMd['sizeBytes'] as int? ?? 0),
    // Daily logs
    'logFileCount': '${dailyLogs['fileCount'] ?? 0}',
    'logTotalSize': formatBytes(dailyLogs['totalSizeBytes'] as int? ?? 0),
    'dailyLogs': logRows,
    'hasDailyLogs': logRows.isNotEmpty,
  };
}

String _formatTimestamp(String? iso) => formatRelativeTimeIso(iso);

String _fillPercent(int count, int cap) {
  if (cap <= 0) return '0%';
  return '${(count * 100 / cap).round()}%';
}

/// Canon's empty-meter treatment, so a track with nothing in it reads as an
/// unfilled slot rather than as a solid rule.
String _emptyMeterClass(int amount) => amount == 0 ? 'meter--empty' : '';

/// [formatBytes] renders `"<amount> <unit>"`; the two halves are split so the
/// amount can hold the tile's centre line and the unit hang beside it.
String _byteAmount(int bytes) => formatBytes(bytes).split(' ').first;

String _byteUnit(int bytes) => formatBytes(bytes).split(' ').last;

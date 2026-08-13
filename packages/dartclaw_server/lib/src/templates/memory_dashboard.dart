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
  final collection = status['collection'] as Map<String, dynamic>? ?? const {};
  final promptIndex = status['promptIndex'] as Map<String, dynamic>? ?? const {};
  final observations = status['observations'] as Map<String, dynamic>? ?? const {};
  final index = status['index'] as Map<String, dynamic>? ?? const {};
  final curation = status['curation'] as Map<String, dynamic>?;

  // Memory size budget
  final sizeBytes = memoryMd['coverage'] == 'lowerBound' ? null : memoryMd['sizeBytes'] as int?;
  final budgetBytes = memoryMd['budgetBytes'] as int? ?? config['memoryMaxBytes'] as int? ?? 32768;
  final budgetPercent = sizeBytes != null && budgetBytes > 0 ? (sizeBytes * 100 / budgetBytes).round() : null;
  final budgetOver = budgetPercent != null && budgetPercent > 100;
  final budgetWarn = budgetPercent != null && budgetPercent >= 80;
  // The tile is tinted by how close the workspace is to its budget, never by
  // which metric it is; the cue repeats the threshold in words so the reading
  // survives with colour removed.
  final budgetCue = budgetOver ? 'Over limit' : (budgetWarn ? 'Near limit' : null);

  final collectionAvailable = collection['state'] == 'available';
  final hasCollectionProjection = status.containsKey('collection');
  final activeCount = hasCollectionProjection
      ? (collectionAvailable ? collection['curatedEntryCount'] as int? : null)
      : memoryMd['entryCount'] as int?;
  final archivedCount = hasCollectionProjection
      ? (collectionAvailable ? collection['archiveEntryCount'] as int? : null)
      : archiveMd['entryCount'] as int?;
  final learningsCount = hasCollectionProjection
      ? (collectionAvailable ? collection['learningEntryCount'] as int? : null)
      : learningsMd['entryCount'] as int?;
  final errorsCount = errorsMd['coverage'] == 'lowerBound' ? null : errorsMd['entryCount'] as int?;
  final errorsPercent = _fillPercent(errorsCount ?? 0, errorsMd['cap'] as int? ?? 50);
  final learningsPercent = _fillPercent(learningsCount ?? 0, learningsMd['cap'] as int? ?? 50);

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
    'memorySizeValue': sizeBytes == null ? 'unknown' : _byteAmount(sizeBytes),
    'memorySizeUnit': sizeBytes == null ? '' : _byteUnit(sizeBytes),
    'memorySizeCardClass': budgetOver ? 'card-metric--error' : (budgetWarn ? 'card-metric--warning' : ''),
    'budgetStr': formatBytes(budgetBytes),
    'budgetPercentLabel': budgetPercent == null
        ? 'unknown'
        : budgetCue == null
        ? '$budgetPercent%'
        : '$budgetCue · $budgetPercent%',
    'budgetBarWidth': '${budgetPercent ?? 0}%',
    'budgetWarnClass': budgetOver ? 'meter-fill--error' : (budgetWarn ? 'meter-fill--warning' : ''),
    'budgetMeterEmptyClass': _emptyMeterClass(budgetPercent ?? 0),
    'entryCount': _known(activeCount),
    'archivedCount': _known(archivedCount),
    'errorsCount': _known(errorsCount),
    'errorsCapLabel': '/ ${errorsMd['cap'] ?? 50}',
    'errorsCardClass': errorsCount != null && errorsCount > 0 ? 'card-metric--error' : '',
    'errorsPercent': errorsPercent,
    'errorsMeterEmptyClass': _emptyMeterClass(errorsCount ?? 0),
    'learningsCount': _known(learningsCount),
    'learningsCapLabel': '/ ${learningsMd['cap'] ?? 50}',
    'learningsPercent': learningsPercent,
    'learningsMeterEmptyClass': _emptyMeterClass(learningsCount ?? 0),
    // Canonical lifecycle
    'collectionRevision': _known(collection['revision']),
    'curatedRoleCount': _known(collection['curatedEntryCount']),
    'topicRoleCount': _known(collection['topicCount']),
    'archiveRoleCount': _known(collection['archiveEntryCount']),
    'learningRoleCount': _known(collection['learningEntryCount']),
    'opaqueLegacyCount': _known(collection['opaqueLegacyCount']),
    'opaqueLegacyLocators': _joinedBounded(collection['opaqueLegacyLocators']),
    'collectionUnknown': collection['state'] != 'available',
    'migrationState': _stateLabel((collection['migration'] as Map?)?['state']?.toString() ?? 'unknown'),
    'migrationSnapshot': (collection['migration'] as Map?)?['snapshotPath']?.toString(),
    'migrationSnapshotAbsent': absentValue((collection['migration'] as Map?)?['snapshotPath']).isAbsent,
    'migrationAction': (collection['migration'] as Map?)?['action']?.toString(),
    'promptBytes': _usage(promptIndex['usedBytes'], promptIndex['budgetBytes']),
    'promptLines': _usage(promptIndex['usedLines'], promptIndex['lineBudget']),
    'promptTruncated': promptIndex['truncated'] == true,
    'promptReason': promptIndex['reason']?.toString(),
    'observationCount': _known(observations['entryCount']),
    'observationUsage': _observationUsage(observations),
    'observationCoverage': _stateLabel(observations['usageKind']?.toString() ?? 'unknown'),
    'observationWarning': observations['warning']?.toString() ?? 'unknown',
    'observationWarningClass': _badgeClass(observations['warning']?.toString() ?? 'unknown'),
    'observationScanned': _known(observations['scannedFiles']),
    'observationOmitted': _known(observations['omittedFiles']),
    'observationFailed': _known(observations['failedFiles']),
    'observationOldest': _formatTimestamp(observations['oldestRecorded']?.toString()),
    'observationNewest': _formatTimestamp(observations['newestRecorded']?.toString()),
    'indexState': _stateLabel(index['state']?.toString() ?? 'unknown'),
    'indexBadgeClass': _badgeClass(index['state']?.toString() ?? 'unknown'),
    'indexCanonicalRevision': _known(index['canonicalRevision']),
    'indexRevision': _known(index['indexedRevision']),
    'derivedChunkCount': _known(index['derivedChunkCount']),
    'wikiSourceCount': _known(index['wikiSourceCount']),
    'indexLastReconciliation': _formatTimestamp(index['lastReconciliationAt']?.toString()),
    'indexFailureStage': index['failureStage']?.toString(),
    'indexReason': index['reason']?.toString(),
    'indexAction': index['action']?.toString(),
    'hasCuration': curation != null,
    'curationState': _stateLabel(curation?['state']?.toString() ?? 'Not run'),
    'curationBadgeClass': _badgeClass(curation?['state']?.toString() ?? 'idle'),
    'curationRunning': curation?['state'] == 'running',
    'curationStarted': _formatTimestamp(curation?['startedAt']?.toString()),
    'curationCompleted': _formatTimestamp(curation?['completedAt']?.toString()),
    'curationLastSuccess': _formatTimestamp(curation?['lastSuccessAt']?.toString()),
    'curationCommittedRevision': _known(curation?['committedRevision']),
    'curationCurrentRevision': _known(curation?['currentRevision']),
    'curationChangedIds': _joined(curation?['changedIds']),
    'curationNoOpIds': _joined(curation?['noOpIds']),
    'curationOperationReasons': _mapJoinedBounded(curation?['operationReasons']),
    'curationReason': curation?['failureReason']?.toString() ?? curation?['reason']?.toString(),
    'curationAction': curation?['action']?.toString(),
    // Pruner
    'prunerStatus': prunerStatus[0].toUpperCase() + prunerStatus.substring(1),
    'prunerBadgeClass': prunerBadgeClass,
    'prunerSchedule': pruner['schedule'] as String?,
    'prunerScheduleAbsent': absentValue(pruner['schedule']).isAbsent,
    'prunerArchiveDays': '${pruner['archiveAfterDays'] ?? 90}',
    'prunerNextRun': formatRemainingTimeIso(pruner['nextRun'] as String?),
    'prunerNextRunIso': isoTitle(pruner['nextRun'] as String?),
    'prunerUndated': '${pruner['undatedCount'] ?? 0}',
    'hasUndated': (pruner['undatedCount'] as int? ?? 0) > 0,
    'hasPrunerHistory': prunerHistoryRows.isNotEmpty,
    'prunerHistory': prunerHistoryRows,
    // Search
    'searchState': _stateLabel(index['state']?.toString() ?? 'unknown'),
    'searchBadgeClass': _badgeClass(index['state']?.toString() ?? 'unknown'),
    'searchBackend': search['backend'] as String?,
    'searchBackendAbsent': absentValue(search['backend']).isAbsent,
    'searchDepth': '${search['depth'] ?? 0}',
    'searchIndexTotal': _known(index['derivedChunkCount']),
    'searchDbSize': search['dbSizeBytes'] == null ? 'unknown' : formatBytes(search['dbSizeBytes'] as int),
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

String _known(Object? value) => value?.toString() ?? 'unknown';

String _usage(Object? used, Object? budget) => used == null || budget == null ? 'unknown' : '$used / $budget';

String _observationUsage(Map<String, dynamic> observations) {
  final bytes = observations['usageBytes'];
  if (bytes == null) return 'unknown';
  return observations['usageKind'] == 'lowerBound'
      ? 'at least ${formatBytes(bytes as int)}'
      : formatBytes(bytes as int);
}

String _joined(Object? value) {
  if (value is! List || value.isEmpty) return 'none';
  return value.map((item) => item.toString()).join(', ');
}

String _joinedBounded(Object? value) {
  if (value is! List || value.isEmpty) return 'none';
  final shown = value.take(10).map((item) => item.toString()).join(', ');
  return value.length <= 10 ? shown : '$shown, … ${value.length - 10} more';
}

String _mapJoinedBounded(Object? value) {
  if (value is! Map || value.isEmpty) return 'none';
  final shown = value.entries.take(10).map((entry) => '${entry.key}: ${entry.value}').join('; ');
  return value.length <= 10 ? shown : '$shown; … ${value.length - 10} more';
}

String _stateLabel(String value) => value.isEmpty
    ? 'Unknown'
    : value.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (match) => '${match[1]} ${match[2]}').toLowerCase();

String _badgeClass(String state) => switch (state) {
  'healthy' || 'succeeded' || 'none' => 'status-badge-success',
  'failed' => 'status-badge-error',
  'running' || 'rebuilding' => 'status-badge-running',
  'conflicted' => 'status-badge-warning',
  'degraded' || 'unknown' || 'active' => 'status-badge-warning',
  _ => 'status-badge-muted',
};

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

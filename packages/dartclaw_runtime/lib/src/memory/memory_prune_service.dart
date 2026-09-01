import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show KvService, MemoryPruner;
import 'package:logging/logging.dart';

final _log = Logger('MemoryPruneService');
typedef MemoryPruneResult = ({int entriesArchived, int duplicatesRemoved, int entriesRemaining, int finalSizeBytes});

final class MemoryPruneService {
  const new({this.pruner, this.kvService});
  final MemoryPruner? pruner;
  final KvService? kvService;
  Future<MemoryPruneResult?> prune() async {
    final configuredPruner = pruner;
    if (configuredPruner == null) return null;
    final result = await configuredPruner.prune();
    final applied = (
      entriesArchived: result.entriesArchived,
      duplicatesRemoved: result.duplicatesRemoved,
      entriesRemaining: result.entriesRemaining,
      finalSizeBytes: result.finalSizeBytes,
    );
    if (kvService case final kv?) await _appendPruneHistory(kv, applied);
    return applied;
  }
}

Map<String, int> memoryPruneJson(MemoryPruneResult result) => {
  'entriesArchived': result.entriesArchived,
  'duplicatesRemoved': result.duplicatesRemoved,
  'entriesRemaining': result.entriesRemaining,
  'finalSizeBytes': result.finalSizeBytes,
};
Future<void> _appendPruneHistory(KvService kv, MemoryPruneResult result) async {
  List<dynamic> history = [];
  try {
    final parsed = jsonDecode(await kv.get('prune_history') ?? '[]');
    if (parsed is List) history = parsed;
  } catch (e) {
    _log.fine('Could not read prune history, starting fresh: $e');
  }
  history.add({'timestamp': DateTime.now().toUtc().toIso8601String(), ...memoryPruneJson(result)});
  if (history.length > 10) history = history.sublist(history.length - 10);
  await kv.set('prune_history', jsonEncode(history));
}

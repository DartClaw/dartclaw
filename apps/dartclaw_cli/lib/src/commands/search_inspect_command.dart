import 'connected_command_support.dart';

class SearchInspectCommand extends ConnectedCommand {
  new({super.config, super.apiClient, super.writeLine, super.stderrLine, super.exitFn}) {
    argParser
      ..addOption('corpus', allowed: ['memory', 'conversation'], mandatory: true)
      ..addOption('query', mandatory: true)
      ..addOption('limit', defaultsTo: '20')
      ..addFlag('json', negatable: false);
  }

  @override
  String get name => 'inspect';

  @override
  String get description => 'Inspect hybrid retrieval sources and ranking evidence';

  @override
  Future<void> run() async {
    final query = argResults!['query'] as String;
    final limit = int.tryParse(argResults!['limit'] as String);
    if (query.trim().isEmpty || limit == null || limit < 1 || limit > 20) {
      usageException('Supply a nonblank query and a limit from 1 to 20');
    }
    await runConnected((apiClient) async {
      final result = await apiClient.postObject(
        '/api/search/inspect',
        body: {'corpus': argResults!['corpus'], 'query': query, 'limit': limit},
      );
      if (argResults!['json'] as bool) {
        writePrettyJson(writeLine, result);
        return;
      }
      for (final hit in result['results'] as List) {
        final provenance = hit['locator'] ?? '${hit['sessionId']}/${hit['messageId']}';
        writeLine('$provenance [${hit['role']}] score=${hit['score']}');
        writeLine(hit['snippet'] as String);
      }
      final diagnostics = result['diagnostics'] as Map;
      for (final candidate in diagnostics['candidates'] as List) {
        writeLine(
          '${candidate['documentId']}#${candidate['chunkIndex']} ${candidate['sourceLayer']}: '
          'keyword=${candidate['keywordRank'] ?? '-'} vector=${candidate['vectorRank'] ?? '-'} '
          'contributions=${candidate['keywordContribution']}+${candidate['vectorContribution']} '
          'fused=${candidate['fusedScore']}',
        );
      }
      writeLine('Unembedded: ${diagnostics['unembeddedCount']}');
      for (final degradation in diagnostics['degradations'] as List) {
        writeLine('${degradation['layer']}: ${degradation['reason']}');
      }
    });
  }
}

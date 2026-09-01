import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

typedef SourceFile = ({String path, String source});

void main() {
  group('memory architecture scanners', () {
    for (final fixture in <({String name, SourceFile file, String message})>[
      (
        name: 'curation write around the apply service',
        file: (
          path: 'lib/wiring.dart',
          source:
              'final curationSnapshot = await corpus.curationSnapshot(maxIndexBytes: 1); '
              'await corpus.changeSelected(prepare: rewrite);',
        ),
        message: 'curation writes go through MemoryApplyService.apply',
      ),
      (
        name: 'curation job committing to the corpus itself',
        file: (
          path: 'lib/memory_curation_job.dart',
          source: 'ScheduledJob buildMemoryCurationJob() => job; await corpus.commit(replacement);',
        ),
        message: 'curation writes go through MemoryApplyService.apply',
      ),
      (
        name: 'durable curation lifecycle record',
        file: (path: 'lib/lifecycle.dart', source: 'final class CurationRunRecord { final String runId; }'),
        message: 'curation keeps no durable run record',
      ),
      (
        name: 'durable curation lifecycle key',
        file: (path: 'lib/lifecycle.dart', source: "await kv.set('memory_curation', jsonEncode(state));"),
        message: 'curation keeps no durable run record',
      ),
      (
        name: 'generic locator',
        file: (path: 'lib/result.dart', source: "MemorySearchResult(locator: 'archive');"),
        message: 'Use the canonical entry ID',
      ),
      (
        name: 'caller-owned FTS encoding',
        file: (path: 'lib/caller.dart', source: 'MemoryService.encodeNaturalLanguageQuery(query);'),
        message: 'Pass natural language to SearchBackend',
      ),
      (
        name: 'retired placeholder',
        file: (path: 'lib/api.dart', source: 'MemoryChunk? current;'),
        message: 'use canonical entries or MemorySearchResult',
      ),
    ]) {
      test('${fixture.name} fixture fails with remediation', () {
        final violations = scanMemoryArchitecture([fixture.file]);
        expect(violations, hasLength(1));
        expect(violations.single, contains(fixture.message));
      });
    }

    test('canonical seams pass', () {
      expect(
        scanMemoryArchitecture(const [
          (
            path: 'lib/memory_curation_job.dart',
            source:
                'final snapshot = await corpus.curationSnapshot(maxIndexBytes: maxIndexBytes); '
                'applyService.registerRunScope(sessionId, ids);',
          ),
          (path: 'lib/wiring.dart', source: 'buildMemoryCurationJob(cronExpression: cron, corpus: corpus);'),
          (path: 'lib/search.dart', source: 'backend.search(query);'),
          (path: 'lib/result.dart', source: 'MemorySearchResult(locator: entry.id);'),
          (path: 'lib/commit.dart', source: 'await corpus.changeSelected(prepare: unrelatedRewrite);'),
        ]),
        isEmpty,
      );
    });

    test('production tree contains no prohibited memory seam', () {
      final root = findRepoRoot();
      final files = productionDartFiles(root)
          .where((file) => !_generated(file.path))
          .map((file) => (path: relativeTo(file.path, root), source: file.readAsStringSync()));
      expect(scanMemoryArchitecture(files), isEmpty);
    });

    for (final fixture in const [
      (
        packageName: 'core',
        barrelPath: 'packages/dartclaw_core/lib/dartclaw_core.dart',
        exportPath: 'src/memory/canonical_memory.dart',
        declarationPath: 'packages/dartclaw_core/lib/src/memory/canonical_memory.dart',
        usedSymbol: 'UsedMemoryType',
        deadSymbol: 'DeadMemoryType',
        consumerPath: 'packages/dartclaw_runtime/lib/src/status.dart',
      ),
      (
        packageName: 'core storage',
        barrelPath: 'packages/dartclaw_core/lib/dartclaw_core.dart',
        exportPath: 'src/storage/index_reconciler.dart',
        declarationPath: 'packages/dartclaw_core/lib/src/storage/index_reconciler.dart',
        usedSymbol: 'UsedRecoveryType',
        deadSymbol: 'DeadRecoveryType',
        consumerPath: 'apps/dartclaw_cli/lib/src/status.dart',
      ),
      (
        packageName: 'server',
        barrelPath: 'packages/dartclaw_runtime/lib/src/memory/memory_exports.dart',
        exportPath: 'memory_status_service.dart',
        declarationPath: 'packages/dartclaw_runtime/lib/src/memory/memory_status_service.dart',
        usedSymbol: 'UsedStatusType',
        deadSymbol: 'DeadStatusCallback',
        consumerPath: 'apps/dartclaw_cli/lib/src/status.dart',
      ),
    ]) {
      test('exported ${fixture.packageName} memory API without a production consumer fails with remediation', () {
        final violations = scanUnconsumedMemoryApi([
          (
            path: fixture.barrelPath,
            source: "export '${fixture.exportPath}' show ${fixture.usedSymbol}, ${fixture.deadSymbol};",
          ),
          (path: fixture.declarationPath, source: 'class ${fixture.usedSymbol} {} class ${fixture.deadSymbol} {}'),
          (path: fixture.consumerPath, source: 'final ${fixture.usedSymbol}? status = null;'),
        ]);
        expect(violations, hasLength(1));
        expect(violations.single, contains(fixture.deadSymbol));
        expect(violations.single, contains('unexport it or add a production consumer'));
      });
    }

    test('every exported core, storage, and server memory API has a production consumer', () {
      final root = findRepoRoot();
      final files = productionDartFiles(root)
          .where((file) => !_generated(file.path))
          .map((file) => (path: relativeTo(file.path, root), source: file.readAsStringSync()))
          .toList(growable: false);
      expect(scanUnconsumedMemoryApi(files), isEmpty);
    });
  });

  group('current memory documentation', () {
    test('obsolete prose fixture fails with remediation', () {
      final violations = scanCurrentMemoryDocs(const [
        (path: 'docs/guide/architecture.md', source: 'The public MemoryChunk is the source of truth.'),
      ]);
      expect(violations.single, contains('describe canonical entries and the derived index'));
    });

    test('obsolete canonical path fixture fails with remediation', () {
      final violations = scanCurrentMemoryDocs(const [
        (path: 'dev/architecture/data-model.md', source: 'memory-topics/preferences.md'),
      ]);
      expect(violations.single, contains('memory/topics/'));
    });

    test('retired automatic consolidation prose fails with remediation', () {
      final violations = scanCurrentMemoryDocs(const [
        (
          path: 'docs/guide/agents.md',
          source: 'Heartbeat automatically consolidates personal memory with memory_save.',
        ),
      ]);
      expect(violations, hasLength(2));
      expect(violations, everyElement(contains('explicit memory curation')));
    });

    test('explicit denial of automatic consolidation remains valid', () {
      expect(
        scanCurrentMemoryDocs(const [
          (path: 'docs/guide/agents.md', source: 'Heartbeat does not automatically consolidate personal memory.'),
        ]),
        isEmpty,
      );
    });

    test('stale MEMORY body and prompt-refresh prose fails with remediation', () {
      final violations = scanCurrentMemoryDocs(const [
        (path: 'docs/guide/configuration.md', source: 'Distill daily turn logs into MEMORY.md.'),
        (path: 'docs/guide/configuration.md', source: 'MEMORY.md is the persistent knowledge base.'),
        (
          path: 'docs/guide/configuration.md',
          source: 'Claude and Codex receive behavior files when the server starts.',
        ),
        (path: 'docs/guide/recipes/_common-patterns.md', source: 'Verify MEMORY.md has been updated.'),
        (path: 'dev/architecture/data-model.md', source: 'If MEMORY.md is deleted, long-term memory is lost.'),
      ]);
      expect(violations, hasLength(5));
      expect(violations, everyElement(contains('canonical')));
    });

    test('stale MEMORY pruning prose fails with remediation', () {
      final violations = scanCurrentMemoryDocs(const [
        (path: 'docs/guide/configuration.md', source: 'The scheduled MEMORY.md cleanup job runs nightly.'),
        (path: 'docs/guide/workspace.md', source: 'MEMORY.md pruning into MEMORY.archive.md.'),
        (path: 'dev/architecture/data-model.md', source: 'Opaque content stays in place during MEMORY.md pruning.'),
      ]);
      expect(violations, hasLength(3));
      expect(violations, everyElement(contains('canonical-entry pruning')));
    });

    test('stale PreCompact notification prose fails with remediation', () {
      final violations = scanCurrentMemoryDocs(const [
        (
          path: 'dev/architecture/control-protocol.md',
          source: 'PreCompact hooks are non-blocking lifecycle notifications. DartClaw responds with allow.',
        ),
      ]);
      expect(violations.single, contains('bounded canonical observation capture'));
    });

    for (final fixture in <({String name, String source, String remediation})>[
      (
        name: 'chronological MEMORY stream',
        source: 'MEMORY.md remains the chronological memory stream.',
        remediation: 'bounded canonical index',
      ),
      (
        name: 'observation eviction',
        source: 'Daily logs show removed oldest records.',
        remediation: 'reject partition overflow',
      ),
      (
        name: 'noncanonical observations',
        source: 'Daily logs are not part of canonical memory or the default FTS5 index.',
        remediation: 'canonical indexed observations',
      ),
      (name: 'silent QMD fallback', source: 'QMD falls back to FTS5 silently.', remediation: 'visible QMD degradation'),
      (
        name: 'MEMORY index as research body',
        source: 'MEMORY.md stores research findings. Check MEMORY.md for previous research.',
        remediation: 'memory_search and memory_read',
      ),
    ]) {
      test('${fixture.name} prose fails with remediation', () {
        final violations = scanCurrentMemoryDocs([(path: 'docs/guide/workspace.md', source: fixture.source)]);
        expect(violations, hasLength(1));
        expect(violations.single, contains(fixture.remediation));
      });
    }

    test('normative documents contain no retired operational model', () {
      final root = findRepoRoot();
      expect(scanCurrentMemoryDocs(_normativeDocs(root)), isEmpty);
    });
  });
}

List<String> scanMemoryArchitecture(Iterable<SourceFile> files) {
  final violations = <String>[];
  for (final file in files) {
    final source = file.source;
    // The corpus service declares the mutators; every other curation-aware file
    // has to reach them through MemoryApplyService, which owns CAS, the closed
    // change-set validation, the audit record, and the bounded-snapshot scope.
    const corpusWriters = ['memory/memory_corpus_service.dart', 'memory/memory_apply_service.dart'];
    if (_mentionsCuration(source) && !corpusWriters.any(file.path.endsWith)) {
      final corpusWrite = RegExp(r'\.\s*(?:changeSelected|commit|writeCanonical|replaceCanonical)\s*(?:<[^>]*>\s*)?\(');
      if (corpusWrite.hasMatch(source)) {
        violations.add(
          '${file.path}: curation writes go through MemoryApplyService.apply; it owns CAS, validation, audit, '
          'and the bounded-snapshot scope.',
        );
      }
    }
    if (RegExp(r"""\bclass\s+\w*Curation\w*(?:Record|State|Lifecycle)\b|['"]memory_curation['"]""").hasMatch(source)) {
      violations.add(
        '${file.path}: curation keeps no durable run record; a run is observable through scheduling, delivery, '
        'and logs like any other job.',
      );
    }
    if (RegExp(r'''\blocator\s*:\s*['"](?:memory_save|archive)['"]''').hasMatch(source)) {
      violations.add('${file.path}: Use the canonical entry ID or native source locator, not a generic memory source.');
    }
    if (source.contains('encodeNaturalLanguageQuery') &&
        !file.path.endsWith('storage/memory_service.dart') &&
        !file.path.endsWith('search/fts5_search_backend.dart')) {
      violations.add('${file.path}: Pass natural language to SearchBackend; Fts5SearchBackend owns MATCH encoding.');
    }
    // Not redundant with the analyzer: `dart analyze` fails on a *reference* to
    // a symbol that no longer exists. It has nothing to say about the symbol
    // being declared again, which is the regression this names.
    for (final symbol in const [
      'MemoryChunk',
      'searchVector',
      'insertChunkIfAbsent',
      'deleteChunkIdentity',
      'PromptScope.evaluator',
    ]) {
      if (source.contains(symbol)) {
        violations.add('${file.path}: Retired $symbol is forbidden; use canonical entries or MemorySearchResult.');
      }
    }
  }
  return violations;
}

List<String> scanCurrentMemoryDocs(Iterable<SourceFile> files) {
  final violations = <String>[];
  for (final file in files) {
    for (final term in const ['MemoryChunk', 'PromptScope.evaluator']) {
      if (file.source.contains(term)) {
        violations.add('${file.path}: retired $term; describe canonical entries and the derived index instead.');
      }
    }
    if (file.source.contains('memory-topics/')) {
      violations.add('${file.path}: retired memory-topics/ path; use canonical memory/topics/.');
    }
    if (RegExp(r'\bmemory_save\b', caseSensitive: false).hasMatch(file.source)) {
      violations.add('${file.path}: retired memory_save prose; describe explicit memory curation and canonical tools.');
    }
    if (_hasAffirmativeAutomaticConsolidation(file.source)) {
      violations.add(
        '${file.path}: retired automatic consolidation prose; describe explicit memory curation and its run-now action.',
      );
    }
    if (RegExp(
      r'(?:chronological[^\n]{0,40}`?MEMORY\.md`?|`?MEMORY\.md`?[^\n]{0,40}chronological)[^\n]{0,20}stream',
      caseSensitive: false,
    ).hasMatch(file.source)) {
      violations.add('${file.path}: retired chronological MEMORY stream; describe the bounded canonical index.');
    }
    if (RegExp(r'removed?\s+(?:the\s+)?oldest\s+records?', caseSensitive: false).hasMatch(file.source)) {
      violations.add('${file.path}: observation eviction is retired; reject partition overflow without deletion.');
    }
    if (RegExp(
      r'(?:daily logs|observations)[^\n]{0,120}not part of canonical memory',
      caseSensitive: false,
    ).hasMatch(file.source)) {
      violations.add('${file.path}: describe canonical indexed observations, not noncanonical daily logs.');
    }
    if (RegExp(r'falls? back to FTS5 silently', caseSensitive: false).hasMatch(file.source)) {
      violations.add('${file.path}: QMD fallback must name visible QMD degradation.');
    }
    if (RegExp(
      r'(?:MEMORY\.md[^\n]{0,80}\b(?:stores?|contains?|holds?)\b|\b(?:check|review|inspect|read)[^\n]{0,80}MEMORY\.md\b)',
      caseSensitive: false,
    ).hasMatch(file.source)) {
      violations.add(
        '${file.path}: MEMORY.md is a bounded index; retrieve detailed entries through memory_search and memory_read.',
      );
    }
    if (RegExp(
      r'(?:\b(?:distill|save|write)[^\n]{0,80}\b(?:into|to)\s+`?MEMORY\.md|MEMORY\.md[^\n]{0,80}\bpersistent knowledge base\b|\bverify[^\n]{0,80}MEMORY\.md[^\n]{0,40}\bupdated\b|MEMORY\.md[^\n]{0,40}\bdeleted\b[^\n]{0,60}\blong-term memory\b)',
      caseSensitive: false,
    ).hasMatch(file.source)) {
      violations.add('${file.path}: describe canonical topic, observation, and bounded-index authority.');
    }
    if (RegExp(
      r'Claude and Codex[^\n]{0,100}\b(?:receive|read)[^\n]{0,100}\bserver starts?\b',
      caseSensitive: false,
    ).hasMatch(file.source)) {
      violations.add('${file.path}: describe fresh per-turn canonical prompt composition.');
    }
    if (RegExp(
      r'(?:scheduled\s+MEMORY\.md\s+cleanup|MEMORY\.md\s+prun\w*|opaque content stays[^\n]{0,80}MEMORY\.md)',
      caseSensitive: false,
    ).hasMatch(file.source)) {
      violations.add('${file.path}: describe canonical-entry pruning and bounded-index regeneration.');
    }
    if (RegExp(
      r'PreCompact[^\n]{0,80}non-blocking lifecycle notifications?',
      caseSensitive: false,
    ).hasMatch(file.source)) {
      violations.add('${file.path}: describe bounded canonical observation capture before acknowledgement.');
    }
  }
  return violations;
}

List<String> scanUnconsumedMemoryApi(Iterable<SourceFile> files) {
  final allFiles = files.toList(growable: false);
  final violations = <String>[];
  for (final barrel in allFiles.where((file) => _memoryBarrelPackage(file.path) != null)) {
    final package = _memoryBarrelPackage(barrel.path)!;
    final exports = RegExp(r"export '([^']+\.dart)'\s+show\s+([^;]+);", dotAll: true).allMatches(barrel.source);
    for (final export in exports) {
      final exportedPath = export.group(1)!;
      if (!_isMemoryExport(package, exportedPath)) continue;
      final declarationPath = p.posix.normalize(p.posix.join(p.posix.dirname(barrel.path), exportedPath));
      final symbols = export.group(2)!.split(',').map((symbol) => symbol.trim()).where((symbol) => symbol.isNotEmpty);
      final consumerTokens = allFiles
          .where((file) => file.path != barrel.path && file.path != declarationPath)
          .expand((file) => _codeIdentifiers(file.source))
          .toSet();
      for (final symbol in symbols) {
        if (!consumerTokens.contains(symbol) &&
            !_returnedContractHasProductionCaller(symbol, allFiles, declarationPath, consumerTokens)) {
          violations.add(
            '${barrel.path}: exported $symbol has no production consumer; unexport it or add a production consumer.',
          );
        }
      }
    }
  }
  return violations;
}

bool _returnedContractHasProductionCaller(
  String symbol,
  List<SourceFile> files,
  String declarationPath,
  Set<String> consumerTokens,
) {
  final declaration = files.where((file) => file.path == declarationPath).firstOrNull;
  if (declaration == null) return false;
  final methods = RegExp('(?:Future\\s*<\\s*)?${RegExp.escape(symbol)}\\s*>?\\s+([a-zA-Z_]\\w*)\\s*\\(')
      .allMatches(declaration.source)
      .map((match) => match.group(1)!);
  return methods.any(consumerTokens.contains);
}

String? _memoryBarrelPackage(String path) => switch (path) {
  'packages/dartclaw_core/lib/dartclaw_core.dart' => 'dartclaw_core',
  'packages/dartclaw_runtime/lib/src/memory/memory_exports.dart' => 'dartclaw_runtime',
  _ => null,
};

bool _isMemoryExport(String package, String path) => switch (package) {
  'dartclaw_core' =>
    path.startsWith('src/memory/') ||
        path.startsWith('src/search/') ||
        path == 'src/storage/memory_service.dart' ||
        path == 'src/storage/index_reconciler.dart',
  'dartclaw_runtime' => true,
  _ => false,
};

bool _mentionsCuration(String source) => RegExp('curation', caseSensitive: false).hasMatch(source);

bool _hasAffirmativeAutomaticConsolidation(String source) {
  final pattern = RegExp(
    r'\b(?:automatically|nightly|scheduled(?:ly)?)\s+(?:consolidat\w*|rewrit\w*)',
    caseSensitive: false,
  );
  for (final match in pattern.allMatches(source)) {
    final prefix = source.substring((match.start - 16).clamp(0, match.start), match.start).toLowerCase();
    if (!RegExp(r'\b(?:not|never)\s+$').hasMatch(prefix)) return true;
  }
  return false;
}

Iterable<String> _codeIdentifiers(String source) sync* {
  var index = 0;
  while (index < source.length) {
    final code = source.codeUnitAt(index);
    if (code == 47 && index + 1 < source.length && source.codeUnitAt(index + 1) == 47) {
      index = source.indexOf('\n', index + 2);
      if (index < 0) return;
      continue;
    }
    if (code == 47 && index + 1 < source.length && source.codeUnitAt(index + 1) == 42) {
      final end = source.indexOf('*/', index + 2);
      if (end < 0) return;
      index = end + 2;
      continue;
    }
    if (code == 34 || code == 39) {
      final quote = code;
      index++;
      while (index < source.length) {
        if (source.codeUnitAt(index) == 92) {
          index += 2;
        } else if (source.codeUnitAt(index++) == quote) {
          break;
        }
      }
      continue;
    }
    if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code == 95) {
      final start = index++;
      while (index < source.length) {
        final next = source.codeUnitAt(index);
        if (!((next >= 65 && next <= 90) || (next >= 97 && next <= 122) || (next >= 48 && next <= 57) || next == 95)) {
          break;
        }
        index++;
      }
      yield source.substring(start, index);
      continue;
    }
    index++;
  }
}

Iterable<SourceFile> _normativeDocs(String root) sync* {
  final paths = <String>{'README.md'};
  for (final directory in const ['docs', 'dev/architecture']) {
    for (final file in Directory('$root/$directory').listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('.md')) paths.add(relativeTo(file.path, root));
    }
  }
  paths.addAll(const ['dev/state/DECISIONS.md', 'dev/state/ROADMAP.md', 'dev/state/UBIQUITOUS_LANGUAGE.md']);
  for (final directory in const ['packages', 'apps']) {
    for (final file in Directory('$root/$directory').listSync(recursive: false).whereType<Directory>()) {
      final agents = File('${file.path}/AGENTS.md');
      if (agents.existsSync()) paths.add(relativeTo(agents.path, root));
    }
  }
  for (final path in paths) {
    final file = File('$root/$path');
    yield (path: path, source: file.readAsStringSync());
  }
}

bool _generated(String path) => path.endsWith('.g.dart') || path.contains('/lib/src/generated/');

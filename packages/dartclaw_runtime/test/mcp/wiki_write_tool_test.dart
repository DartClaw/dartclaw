import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGuard;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../guard_audit_test_support.dart';

Future<Map<String, dynamic>> _call(
  McpProtocolHandler handler,
  String name, [
  Map<String, dynamic> arguments = const {},
]) async {
  final raw = await handler.handleRequest(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    }),
  );
  return jsonDecode(raw!) as Map<String, dynamic>;
}

Map<String, dynamic> _result(Map<String, dynamic> response) {
  expect(response['error'], isNull, reason: 'a tool refusal must be a JSON-RPC success carrying isError');
  return response['result'] as Map<String, dynamic>;
}

String _text(Map<String, dynamic> result) =>
    ((result['content'] as List).single as Map<String, dynamic>)['text'] as String;

Map<String, dynamic> _payload(Map<String, dynamic> result) => jsonDecode(_text(result)) as Map<String, dynamic>;

/// A body long enough that a short replacement breaches the store's shrink
/// floor rather than merely differing from it.
String _longBody(String marker) =>
    List.generate(40, (index) => '$marker line $index with enough text to count.').join('\n');

void main() {
  late Directory tempDir;
  late WikiPageStore wiki;
  late RecordingGuardAuditLogger audit;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_wiki_write_tool_');
    wiki = WikiPageStore(workspaceDir: tempDir.path);
    audit = RecordingGuardAuditLogger();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  McpProtocolHandler handlerWith({GuardChain? chain, GuardAuditLogger? sink}) =>
      McpProtocolHandler(guardChain: chain, auditLogger: sink)..registerTool(WikiWriteTool(wiki: wiki));

  McpProtocolHandler passingHandler() => handlerWith(
    chain: GuardChain(guards: [FakeGuard.pass()]),
    sink: audit,
  );

  File pageFile(String slug) => File(p.join(tempDir.path, 'wiki', '$slug.md'));

  List<(String, String)> auditRows() => [for (final entry in audit.entries) (entry.tool ?? '', entry.decision ?? '')];

  group('S08 wiki_write authors through the one page-store entry point', () {
    test('a first write creates the page with its provenance frontmatter', () async {
      final handler = passingHandler();

      final payload = _payload(
        _result(
          await _call(handler, 'wiki_write', {
            'slug': 'dart-roadmap',
            'title': 'Dart Roadmap',
            'body': _longBody('roadmap'),
            'sources': ['inbox/roadmap.md', 'https://dart.dev/roadmap'],
            'confidence': 'high',
          }),
        ),
      );

      expect(payload['slug'], 'dart-roadmap');
      expect(payload['outcome'], WikiPageOutcome.created.name);
      expect(payload['path'], 'wiki/dart-roadmap.md');

      // Frontmatter is the store's to emit; the page must carry the provenance,
      // sources and confidence any ingested page would carry.
      final stored = pageFile('dart-roadmap').readAsStringSync();
      final frontmatter = WikiPageStore.parseFrontmatter(WikiPageStore.splitFrontmatter(stored)!.frontmatter!)!;
      expect(frontmatter['provenance'], 'llm-authored');
      expect(frontmatter['confidence'], 'high');
      expect(WikiPageStore.frontmatterSources(frontmatter['sources']), [
        'inbox/roadmap.md',
        'https://dart.dev/roadmap',
      ]);
      expect(frontmatter['last_updated_by'], wikiWritePrincipal);
      expect(stored, contains('# Dart Roadmap'));
      expect(auditRows(), [('wiki_write', 'allow')]);
    });

    test('a slug escaping the wiki root is refused and writes no page anywhere', () async {
      final handler = passingHandler();

      final result = _result(
        await _call(handler, 'wiki_write', {
          'slug': '../../etc/passwd',
          'title': 'Passwd',
          'body': _longBody('escape'),
          'sources': ['inbox/escape.md'],
        }),
      );

      expect(result['isError'], isTrue);
      final payload = _payload(result);
      expect(payload['reason'], 'slug_refused');
      expect(payload['message'], contains('contained in the wiki directory'));

      // The store sanitizes rather than throws, so the refusal is what stops a
      // page being written under the reduced slug instead of the asked-for one.
      expect(pageFile('etc-passwd').existsSync(), isFalse);
      expect(File(p.join(tempDir.path, 'etc', 'passwd')).existsSync(), isFalse);
      final wikiDir = Directory(p.join(tempDir.path, 'wiki'));
      final written = wikiDir.existsSync()
          ? wikiDir.listSync().map((entry) => p.basename(entry.path)).toSet()
          : <String>{};
      expect(written.difference({'README.md'}), isEmpty);
    });

    test('a body under the store shrink floor is refused and the stored page is left byte-identical', () async {
      final handler = passingHandler();
      _result(
        await _call(handler, 'wiki_write', {
          'slug': 'dart-roadmap',
          'title': 'Dart Roadmap',
          'body': _longBody('roadmap'),
          'sources': ['inbox/roadmap.md'],
        }),
      );
      final before = pageFile('dart-roadmap').readAsBytesSync();

      final result = _result(
        await _call(handler, 'wiki_write', {
          'slug': 'dart-roadmap',
          'title': 'Dart Roadmap',
          'body': 'Roadmap is now short.',
          'sources': ['inbox/summary.md'],
        }),
      );

      expect(result['isError'], isTrue);
      final payload = _payload(result);
      expect(payload['reason'], 'shrink_floor');
      expect(payload['message'], contains('refused a merge shrinking it'));
      expect(payload['required_bytes'], greaterThan(payload['merged_bytes'] as int));
      expect(pageFile('dart-roadmap').readAsBytesSync(), before);
    });

    test('rewriting a stored page with a full-length body replaces it as an integration', () async {
      final handler = passingHandler();
      _result(
        await _call(handler, 'wiki_write', {
          'slug': 'dart-roadmap',
          'title': 'Dart Roadmap',
          'body': _longBody('roadmap'),
          'sources': ['inbox/roadmap.md'],
        }),
      );

      final payload = _payload(
        _result(
          await _call(handler, 'wiki_write', {
            'slug': 'dart-roadmap',
            'title': 'Dart Roadmap',
            'body': _longBody('revised'),
            'sources': ['inbox/revision.md'],
          }),
        ),
      );

      expect(payload['outcome'], WikiPageOutcome.integrated.name);
      final stored = pageFile('dart-roadmap').readAsStringSync();
      expect(stored, contains('revised line 0'));
      expect(stored, isNot(contains('roadmap line 0')));
      // The store's sources union is inherited unchanged.
      final frontmatter = WikiPageStore.parseFrontmatter(WikiPageStore.splitFrontmatter(stored)!.frontmatter!)!;
      expect(WikiPageStore.frontmatterSources(frontmatter['sources']), ['inbox/roadmap.md', 'inbox/revision.md']);
    });
  });

  group('the dispatch seam guards and audits the tool', () {
    test('a blocking guard refuses the call without the tool running', () async {
      final handler = handlerWith(
        chain: GuardChain(guards: [FakeGuard.block('wiki writes denied')]),
        sink: audit,
      );

      final result = _result(
        await _call(handler, 'wiki_write', {
          'slug': 'dart-roadmap',
          'title': 'Dart Roadmap',
          'body': _longBody('roadmap'),
          'sources': ['inbox/roadmap.md'],
        }),
      );

      expect(result['isError'], isTrue);
      expect(_text(result), contains('wiki writes denied'));
      // The tool never ran, so the store was never even bootstrapped.
      expect(pageFile('dart-roadmap').existsSync(), isFalse);
      expect(auditRows(), [('wiki_write', 'deny')]);
    });
  });

  group('the declared argument contract is enforced', () {
    const cases = <({Map<String, dynamic> arguments, String message})>[
      (arguments: {'title': 'T', 'body': 'B', 'sources': <String>[]}, message: 'slug is required'),
      (arguments: {'slug': 's', 'body': 'B', 'sources': <String>[]}, message: 'title is required'),
      (arguments: {'slug': 's', 'title': 'T', 'sources': <String>[]}, message: 'body is required'),
      (arguments: {'slug': 's', 'title': 'T', 'body': 'B'}, message: 'sources is required'),
      (
        arguments: {'slug': 's', 'title': 'T', 'body': 'B', 'sources': 'inbox/one.md'},
        message: 'sources must be an array',
      ),
      (
        arguments: {
          'slug': 's',
          'title': 'T',
          'body': 'B',
          'sources': [7],
        },
        message: 'sources entries must be non-empty strings',
      ),
      (
        arguments: {'slug': 's', 'title': 'T', 'body': '   ', 'sources': <String>[]},
        message: 'body must be a non-empty string',
      ),
      (
        arguments: {'slug': 's', 'title': 'T', 'body': 'B', 'sources': <String>[], 'confidence': 'certain'},
        message: 'confidence must be one of: low, medium, high',
      ),
    ];

    for (final testCase in cases) {
      test(testCase.message, () async {
        final result = _result(await _call(passingHandler(), 'wiki_write', testCase.arguments));

        expect(result['isError'], isTrue);
        expect(_payload(result)['reason'], 'invalid_request');
        expect(_payload(result)['message'], testCase.message);
        // Fail-closed means the refused call also left nothing behind.
        expect(pageFile('s').existsSync(), isFalse);
      });
    }
  });

  group('read/write classification', () {
    test('wiki_write is write-classified and declares a closed schema', () {
      final handler = passingHandler();
      expect(handler.toolAccess, containsPair('wiki_write', McpToolAccess.write));

      final schema = WikiWriteTool(wiki: wiki).inputSchema;
      expect(schema['additionalProperties'], false);
      // Provenance is the store's to decide; a model-supplied one would let a
      // tool-authored page claim the search-trusted tier.
      expect((schema['properties'] as Map).keys, isNot(contains('provenance')));
    });
  });
}

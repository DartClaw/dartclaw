import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart' as loader;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// Proves the wiki document template is reachable through **both** loading
/// modes. Filesystem loading iterates `expectedTemplates`; embedded loading
/// discovers generated assets — generated parity alone cannot prove the
/// source-tree manifest was updated, and the manifest cannot prove the
/// generated bundle contains the file.
void main() {
  late Directory tempDir;
  late KvService kvService;
  late SessionService sessions;
  late MessageService messages;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_wiki_document_test_');
    kvService = KvService(filePath: '${tempDir.path}/kv.json');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    File('${tempDir.path}/workspace/wiki/README.md')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('# Wiki\n\nA `rendered` document.');
  });

  tearDown(() async {
    await kvService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<Response> serveWiki() {
    final handler = webRoutes(
      sessions,
      messages,
      kvService: kvService,
      config: DartclawConfig(server: ServerConfig(dataDir: tempDir.path)),
      dataDir: tempDir.path,
    ).call;
    return handler(Request('GET', Uri.parse('http://localhost/knowledge/wiki/wiki/README.md')));
  }

  void expectRenderedDocument(String body) {
    expect(body, contains('<div class="shell">'));
    expect(body, contains('data-markdown'));
    expect(body, contains('# Wiki'));
    expect(body, contains('README.md'));
  }

  test('the manifest registers wiki_document exactly once', () {
    expect(loader.expectedTemplates.where((name) => name == 'wiki_document').length, 1);
  });

  test('the route renders through non-dev filesystem loading', () async {
    loader.resetTemplates();
    try {
      loader.initTemplates(await resolveTemplatesDir(), devMode: false);
      final res = await serveWiki();

      expect(res.statusCode, 200);
      expectRenderedDocument(await res.readAsString());
    } finally {
      loader.resetTemplates();
    }
  });

  test('the route renders through dev-mode filesystem loading', () async {
    loader.resetTemplates();
    try {
      loader.initTemplates(await resolveTemplatesDir(), devMode: true);
      final res = await serveWiki();

      expect(res.statusCode, 200);
      expectRenderedDocument(await res.readAsString());
    } finally {
      loader.resetTemplates();
    }
  });

  test('the route renders through the real embedded asset bundle', () async {
    loader.resetTemplates();
    try {
      // No assets override: this is the generated embeddedServerAssets map, so
      // a stale bundle fails here rather than silently at runtime.
      loader.initEmbeddedTemplates();
      final res = await serveWiki();

      expect(res.statusCode, 200);
      expectRenderedDocument(await res.readAsString());
    } finally {
      loader.resetTemplates();
    }
  });
}

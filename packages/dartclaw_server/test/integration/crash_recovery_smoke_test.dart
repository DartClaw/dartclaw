@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late Database db;
  late TurnStateStore turnState;
  late KvService kv;
  Process? activeProcess;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_crash_recovery_smoke_');
    db = sqlite3.open('${tempDir.path}/state.db');
    turnState = TurnStateStore(db);
    kv = KvService(filePath: '${tempDir.path}/kv.json');
  });

  tearDown(() async {
    final process = activeProcess;
    activeProcess = null;
    if (process != null) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    await kv.dispose();
    await turnState.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test(
    'reserve/start crash leaves one orphan that restart cleanup clears with one recovery notice',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final helper = File('packages/dartclaw_server/test/integration/_fixtures/crash_turn_process.dart');
      activeProcess = await _startCrashProcess(helper, tempDir);

      final stderrBuffer = StringBuffer();
      activeProcess!.stderr.transform(SystemEncoding().decoder).listen(stderrBuffer.write);

      final ready = File('${tempDir.path}/crash-turn-ready.json');
      await _until(() async => ready.existsSync(), onTimeout: () => stderrBuffer.toString());
      final payload = jsonDecode(ready.readAsStringSync()) as Map<String, dynamic>;
      final port = payload['port'] as int;

      final session = await _postJson(port, '/api/sessions', const {});
      final sessionId = session['id'] as String;
      await _post(port, '/api/sessions/$sessionId/send', const {'message': 'hold turn open'});
      await _until(() async => (await turnState.getAll())[sessionId] != null);
      final turnId = (await turnState.getAll())[sessionId]!.turnId;
      expect(turnId, isNotEmpty);

      final crashed = activeProcess!;
      activeProcess = null;
      expect(crashed.kill(ProcessSignal.sigkill), isTrue);
      await crashed.exitCode;

      ready.deleteSync();
      activeProcess = await _startCrashProcess(helper, tempDir);
      final restartStderr = StringBuffer();
      activeProcess!.stderr.transform(SystemEncoding().decoder).listen(restartStderr.write);
      await _until(() async => ready.existsSync(), onTimeout: () => restartStderr.toString());
      final restartPayload = jsonDecode(ready.readAsStringSync()) as Map<String, dynamic>;
      final recovered = (restartPayload['recoveredSessions'] as List<dynamic>).cast<String>();
      final restartPort = restartPayload['port'] as int;

      expect(recovered, [sessionId]);
      expect(await turnState.getAll(), isEmpty);

      final messages = MessageService(baseDir: tempDir.path);
      await messages.insertMessage(
        sessionId: sessionId,
        role: 'assistant',
        content: '[Turn failed: worker process crashed]',
      );

      final firstSessionPage = await _get(restartPort, '/sessions/$sessionId');
      expect(firstSessionPage, contains('recovered from an interrupted turn'));
      expect(firstSessionPage, contains('msg-turn-failed'));
      expect(firstSessionPage, contains('worker process crashed'));
      final secondSessionPage = await _get(restartPort, '/sessions/$sessionId');
      expect(secondSessionPage, isNot(contains('recovered from an interrupted turn')));
      expect(secondSessionPage, contains('msg-turn-failed'));
    },
  );
}

Future<Process> _startCrashProcess(File helper, Directory tempDir) {
  return Process.start(Platform.resolvedExecutable, [
    'run',
    helper.path,
    tempDir.path,
  ], workingDirectory: Directory.current.path);
}

Future<Map<String, dynamic>> _postJson(int port, String path, Map<String, dynamic> body) async {
  final text = await _post(port, path, body);
  return jsonDecode(text) as Map<String, dynamic>;
}

Future<String> _get(int port, String path) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      fail('GET $path failed with HTTP ${response.statusCode}: $text');
    }
    return text;
  } finally {
    client.close(force: true);
  }
}

Future<String> _post(int port, String path, Map<String, dynamic> body) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      fail('POST $path failed with HTTP ${response.statusCode}: $text');
    }
    return text;
  } finally {
    client.close(force: true);
  }
}

Future<void> _until(Future<bool> Function() condition, {String Function()? onTimeout}) async {
  for (var i = 0; i < 1000; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final detail = onTimeout?.call();
  fail(detail == null || detail.isEmpty ? 'condition did not become true before timeout' : detail);
}

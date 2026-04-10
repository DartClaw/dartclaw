@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('SIGUSR1 triggers reload in a live process on POSIX hosts', () async {
    if (Platform.isWindows) {
      return;
    }
    final packageRoot = _resolvePackageRoot();

    final tempDir = Directory.systemTemp.createTempSync('reload_trigger_sigusr1_');
    addTearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    final configFile = File(p.join(tempDir.path, 'dartclaw.yaml'));
    await configFile.writeAsString('''
port: 3000
host: localhost
concurrency:
  max_parallel_turns: 2
scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 30
  jobs: []
workspace:
  git_sync:
    enabled: true
    push_enabled: true
''');

    final process = await Process.start(Platform.resolvedExecutable, [
      'test/commands/_reload_trigger_sigusr1_probe.dart',
      configFile.path,
    ], workingDirectory: packageRoot.path);
    addTearDown(() async {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    });

    final stdoutLines = process.stdout.transform(utf8.decoder).transform(const LineSplitter());
    final stderrLines = process.stderr.transform(utf8.decoder).transform(const LineSplitter());
    final stderrSeen = <String>[];
    final stderrSub = stderrLines.listen(stderrSeen.add);
    addTearDown(stderrSub.cancel);

    final iterator = StreamIterator(stdoutLines);
    addTearDown(iterator.cancel);

    final readyLine = await _waitForLine(iterator, 'READY:');
    final pid = int.parse(readyLine.substring('READY:'.length));

    await configFile.writeAsString('''
port: 3000
host: localhost
concurrency:
  max_parallel_turns: 5
scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 30
  jobs: []
workspace:
  git_sync:
    enabled: true
    push_enabled: true
''');

    final signaled = Process.killPid(pid, ProcessSignal.sigusr1);
    expect(signaled, isTrue);

    final appliedLine = await _waitForLine(iterator, 'MAX_PARALLEL:');
    expect(appliedLine, 'MAX_PARALLEL:5', reason: 'stderr: ${stderrSeen.join('\n')}');
  }, timeout: const Timeout(Duration(seconds: 30)));
}

Directory _resolvePackageRoot() {
  final cwd = Directory.current;
  final workspacePath = p.join(cwd.path, 'apps', 'dartclaw_cli');
  if (File(p.join(workspacePath, 'pubspec.yaml')).existsSync()) {
    return Directory(workspacePath);
  }
  if (File(p.join(cwd.path, 'pubspec.yaml')).existsSync() && p.basename(cwd.path) == 'dartclaw_cli') {
    return cwd;
  }
  throw StateError('Could not resolve dartclaw_cli package root from ${cwd.path}');
}

Future<String> _waitForLine(StreamIterator<String> iterator, String prefix) async {
  while (await iterator.moveNext().timeout(const Duration(seconds: 20))) {
    final line = iterator.current;
    final matchIndex = line.indexOf(prefix);
    if (matchIndex >= 0) {
      return line.substring(matchIndex);
    }
  }
  fail('Stream ended before receiving $prefix');
}

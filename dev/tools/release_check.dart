import 'dart:convert';
import 'dart:io';

const _usage = '''Usage: bash dev/tools/release_check.sh --version <version> [options]
  --local       Run local automated gates without contacting GitHub.
  --resume      Reuse intact passes for this exact commit and environment.
  --status      Show recorded results without executing gates.
  --gate <id>   Run or inspect one gate; prerequisites run when needed.
  --quick, -q   Omit workspace tests; always reports incomplete coverage.
Exit codes: 0 = selected gates passed, 1 = failure, 2 = usage, 3 = incomplete.
Automated success is not release approval. See dev/guidelines/RELEASE_PREPARATION.md.
''';

const _ciJobs = ['Check', 'Container boundary', 'PowerShell scripts', 'PostgreSQL contract'];
const _gates = <String, List<List<String>>>{
  'cleanup': [],
  'versions': [
    ['bash', 'dev/tools/check_versions.sh'],
  ],
  'dependencies': [
    ['git', 'ls-files', '--error-unmatch', 'pubspec.lock'],
    ['git', 'ls-files', '--error-unmatch', 'dev/tools/mascot_favicon/pubspec.lock'],
    ['dart', 'pub', 'get', '--enforce-lockfile'],
    ['dart', 'pub', 'get', '--directory', 'dev/tools/mascot_favicon', '--enforce-lockfile'],
    ['git', 'diff', '--exit-code', '--', 'pubspec.lock', 'dev/tools/mascot_favicon/pubspec.lock'],
  ],
  'assets': [
    ['dart', 'run', 'dev/tools/embed_assets.dart'],
  ],
  'format': [
    ['dart', 'format', '--line-length=120', '--output=none', '--set-exit-if-changed', '.'],
  ],
  'analyze': [
    ['dart', 'analyze', '--fatal-infos'],
  ],
  'tests': [
    ['bash', 'dev/tools/test_workspace.sh'],
  ],
  'postgres': [
    ['bash', 'dev/tools/postgres_contract.sh'],
  ],
  'architecture': [
    ['dart', 'run', 'dev/tools/arch_check.dart'],
  ],
  'fitness': [
    ['bash', 'dev/tools/fitness/run_all.sh'],
  ],
  'build': [
    ['bash', 'dev/tools/build.sh'],
  ],
  'whitespace': [
    ['git', 'show', '--format=', '--check', 'HEAD'],
  ],
  'ci': [],
};

// These gates depend on ignored files, external services or generated outputs.
const _alwaysRun = {'cleanup', 'dependencies', 'assets', 'postgres', 'build', 'ci'};
const _needsAssets = {'format', 'analyze', 'tests', 'postgres', 'architecture', 'fitness', 'build'};

Future<void> main(List<String> args) async {
  try {
    exitCode = await _run(args);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.write(_usage);
    exitCode = 2;
  } catch (error) {
    stderr.writeln('Release check failed: $error');
    exitCode = 1;
  }
}

Future<int> _run(List<String> args) async {
  String? version;
  String? gate;
  var local = false;
  var resume = false;
  var statusOnly = false;
  var quick = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--version' || '--gate':
        if (i + 1 == args.length) throw FormatException('${args[i]} requires a value');
        if (args[i] == '--version') {
          version = args[++i];
        } else {
          gate = args[++i];
        }
      case '--local':
        local = true;
      case '--resume':
        resume = true;
      case '--status':
        statusOnly = true;
      case '--quick' || '-q':
        quick = true;
      case '--help' || '-h':
        stdout.write(_usage);
        stdout.writeln('Gates: ${_gates.keys.join(', ')}');
        return 0;
      default:
        throw FormatException('Unknown argument: ${args[i]}');
    }
  }
  if (version == null || !RegExp(r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$').hasMatch(version)) {
    throw const FormatException('--version requires a release version such as 0.27.0');
  }
  if ((gate != null && !_gates.containsKey(gate)) || (local && gate == 'ci') || (quick && gate != null)) {
    throw const FormatException('Unknown gate or conflicting --gate/--local/--quick options');
  }

  final root = File.fromUri(Platform.script).parent.parent.parent.path;
  final check = _ReleaseCheck(root, version);
  final candidate = check.candidate();
  if (!statusOnly && candidate['clean'] != true) {
    stderr.writeln('Release check requires a clean worktree so every verified file is part of HEAD.');
    return 1;
  }
  final environment = await check.environment();
  final selected = gate == null ? _gates.keys.where((id) => !local || id != 'ci').toList() : [gate];
  if (!statusOnly && gate != null && _needsAssets.contains(gate)) {
    selected.insertAll(0, ['dependencies', 'assets']);
  } else if (!statusOnly && gate == 'assets') {
    selected.insert(0, 'dependencies');
  }

  RandomAccessFile? lock;
  try {
    if (!statusOnly) {
      check.directory.createSync(recursive: true);
      lock = File('${check.directory.parent.path}/run.lock').openSync(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
    }
    var failed = false;
    var incomplete = quick;
    for (final id in selected) {
      if (quick && id == 'tests') {
        stdout.writeln('$id: skipped (--quick)');
        continue;
      }
      final recorded = await check.status(id, candidate, environment);
      if (statusOnly) {
        stdout.writeln('$id: $recorded');
        failed |= recorded == 'failed';
        incomplete |= recorded != 'passed';
        continue;
      }
      if (resume && !_alwaysRun.contains(id) && recorded == 'passed') {
        stdout.writeln('$id: passed (reused)');
        continue;
      }
      if (jsonEncode(check.candidate()) != jsonEncode(candidate)) {
        stderr.writeln('Candidate changed; stopping before $id. Earlier evidence is stale.');
        return 1;
      }
      if (!await check.execute(id, candidate, environment)) {
        failed = true;
        break;
      }
    }
    if (!statusOnly && jsonEncode(check.candidate()) != jsonEncode(candidate)) {
      stderr.writeln('Candidate changed; recorded results cannot qualify the current checkout.');
      return 1;
    }
    stdout.writeln('Evidence: ${check.directory.path}');
    stdout.writeln('Manual/live/platform gates remain separate; this command does not authorize tagging.');
    if (failed) return 1;
    if (incomplete) {
      stdout.writeln('Selected coverage is incomplete.');
      return 3;
    }
    stdout.writeln(
      '${gate != null
          ? 'Selected'
          : local
          ? 'Local automated'
          : 'Automated'} gates passed.',
    );
    if (local) stdout.writeln('Exact-commit GitHub Checks remain unverified by this invocation.');
    return 0;
  } finally {
    await lock?.close();
  }
}

class _ReleaseCheck {
  new(this.root, this.version);

  final String root;
  final String version;
  Directory get directory => Directory('$root/.agent_temp/releases/$version');

  String command(List<String> argv) {
    final result = Process.runSync(argv.first, argv.skip(1).toList(), workingDirectory: root);
    if (result.exitCode != 0) throw StateError('${argv.join(' ')}: ${result.stderr}');
    return (result.stdout as String).trim();
  }

  Map<String, Object> candidate() => {
    'version': version,
    'head': command(['git', 'rev-parse', 'HEAD']),
    'tree': command(['git', 'rev-parse', 'HEAD^{tree}']),
    'clean': command(['git', 'status', '--porcelain=v1', '--untracked-files=all']).isEmpty,
  };

  Future<String> hash(String contents) async {
    final process = await Process.start('git', ['hash-object', '--stdin'], workingDirectory: root);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    process.stdin.write(contents);
    await process.stdin.close();
    if (await process.exitCode != 0) throw StateError(await errors);
    return (await output).trim();
  }

  Future<Map<String, Object>> environment() async {
    final keys =
        Platform.environment.keys
            .where(
              (key) =>
                  key == 'PATH' ||
                  key == 'PUB_CACHE' ||
                  key == 'CI' ||
                  key.startsWith('DART') ||
                  key.startsWith('DOCKER_'),
            )
            .toList()
          ..sort();
    return {
      'host': Platform.localHostname,
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'dart': command(['dart', '--version']),
      'runner': Platform.resolvedExecutable,
      'environmentHash': await hash(jsonEncode({for (final key in keys) key: Platform.environment[key]})),
    };
  }

  List<List<String>> commands(String id) => [
    for (final argv in _gates[id]!) [...argv, if (id == 'versions') version],
  ];

  Future<String> status(String id, Map<String, Object> candidate, Map<String, Object> environment) async {
    final dir = Directory('${directory.path}/$id');
    if (!dir.existsSync()) return 'missing';
    final attempts = dir.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
    if (attempts.isEmpty) return 'missing';
    try {
      final receiptFile = File('${attempts.last.path}/receipt.json');
      final expectedHash = File('${attempts.last.path}/receipt.hash').readAsStringSync().trim();
      if (command(['git', 'hash-object', receiptFile.path]) != expectedHash) return 'stale';
      final receipt = jsonDecode(receiptFile.readAsStringSync()) as Map<String, dynamic>;
      final started = DateTime.tryParse(receipt['startedAt'] as String? ?? '');
      if (receipt['schemaVersion'] != 1 ||
          receipt['gate'] != id ||
          receipt['log'] != 'output.log' ||
          started == null ||
          !started.isUtc ||
          candidate['clean'] != true ||
          jsonEncode(receipt['candidate']) != jsonEncode(candidate) ||
          jsonEncode(receipt['environment']) != jsonEncode(environment) ||
          jsonEncode(receipt['commands']) != jsonEncode(commands(id))) {
        return 'stale';
      }
      if (receipt['status'] == 'running') return 'incomplete';
      final finished = DateTime.tryParse(receipt['finishedAt'] as String? ?? '');
      if (!['passed', 'failed'].contains(receipt['status']) ||
          finished == null ||
          !finished.isUtc ||
          finished.isBefore(started) ||
          receipt['exitCode'] is! int ||
          (receipt['status'] == 'passed') != (receipt['exitCode'] == 0)) {
        return 'stale';
      }
      if (id == 'ci' &&
          receipt['status'] == 'passed' &&
          (receipt['ciRunId'] is! int || receipt['ciRunUrl'] is! String || (receipt['ciRunUrl'] as String).isEmpty)) {
        return 'stale';
      }
      final logHash = command(['git', 'hash-object', '${attempts.last.path}/output.log']);
      if (logHash != receipt['logHash']) return 'stale';
      return receipt['status'] as String;
    } on Object {
      return 'stale';
    }
  }

  Future<bool> execute(String id, Map<String, Object> candidate, Map<String, Object> environment) async {
    final started = DateTime.now().toUtc();
    final attempt = Directory('${directory.path}/$id/${started.microsecondsSinceEpoch}-$pid')
      ..createSync(recursive: true);
    final log = File('${attempt.path}/output.log');
    final receipt = <String, Object>{
      'schemaVersion': 1,
      'gate': id,
      'candidate': candidate,
      'environment': environment,
      'commands': commands(id),
      'startedAt': started.toIso8601String(),
      'status': 'running',
      'log': 'output.log',
    };
    void save() {
      final pending = File('${attempt.path}/receipt.json.pending');
      pending.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(receipt)}\n', flush: true);
      pending.renameSync('${attempt.path}/receipt.json');
      final fingerprint = File('${attempt.path}/receipt.hash.pending');
      fingerprint.writeAsStringSync(
        '${command(['git', 'hash-object', '${attempt.path}/receipt.json'])}\n',
        flush: true,
      );
      fingerprint.renameSync('${attempt.path}/receipt.hash');
    }

    save();
    stdout.writeln('$id: running (${log.path})');
    var code = 0;
    final sink = log.openWrite();
    try {
      if (id == 'cleanup') _cleanup();
      if (id == 'ci') _ci(receipt, sink, candidate['head']! as String);
      for (final argv in commands(id)) {
        sink.writeln('> ${argv.join(' ')}');
        final process = await Process.start(argv.first, argv.skip(1).toList(), workingDirectory: root);
        await Future.wait([process.stdout.forEach(sink.add), process.stderr.forEach(sink.add)]);
        code = await process.exitCode;
        if (code != 0) break;
      }
      if (id == 'assets' && code == 0) {
        for (final package in ['dartclaw_runtime', 'dartclaw_workflow']) {
          if (File('$root/packages/$package/lib/src/generated/embedded_assets.g.dart').lengthSync() == 0) {
            throw StateError('Missing generated assets for $package');
          }
        }
      }
      if (jsonEncode(this.candidate()) != jsonEncode(candidate)) {
        throw StateError('Candidate changed during $id; result cannot qualify the starting commit.');
      }
    } catch (error) {
      code = 1;
      sink.writeln(error);
    } finally {
      await sink.close();
    }
    receipt.addAll({
      'status': code == 0 ? 'passed' : 'failed',
      'exitCode': code,
      'finishedAt': DateTime.now().toUtc().toIso8601String(),
      'logHash': command(['git', 'hash-object', log.path]),
    });
    save();
    stdout.writeln('$id: ${receipt['status']} (exit $code)');
    if (code != 0) {
      final lines = log.readAsLinesSync();
      for (final line in lines.skip(lines.length > 40 ? lines.length - 40 : 0)) {
        stderr.writeln(line);
      }
    }
    return code == 0;
  }

  void _cleanup() {
    final leaked = <String>[];
    for (final path in [
      'dev/bundle',
      'dev/specs',
      'dev/research',
      'dev/wireframes',
      'dev/diagrams',
      'dev/testing/evidence',
    ]) {
      final dir = Directory('$root/$path');
      if (dir.existsSync()) {
        leaked.addAll(
          dir
              .listSync(recursive: true, followLinks: false)
              .where((entry) => entry is File && !entry.path.endsWith('/.gitkeep'))
              .map((entry) => entry.path),
        );
      }
    }
    for (final name in [
      'LEARNINGS',
      'STACK',
      'UBIQUITOUS_LANGUAGE',
      'TECH-DEBT-BACKLOG',
      'SPEC-LIFECYCLE',
      'ROADMAP',
      'PRODUCT',
      'PRODUCT-BACKLOG',
      'INSPIRATION-BACKLOG',
    ]) {
      if (File('$root/dev/$name.md').existsSync()) leaked.add('dev/$name.md');
    }
    if (leaked.isNotEmpty) {
      throw StateError('Transient release inputs must be removed before merge:\n${leaked.join('\n')}');
    }
  }

  void _ci(Map<String, Object> receipt, IOSink log, String head) {
    String query(List<String> argv) {
      log.writeln('> ${argv.join(' ')}');
      return command(argv);
    }

    final runs = jsonDecode(
      query([
        'gh',
        'run',
        'list',
        '--workflow',
        'Checks',
        '--commit',
        head,
        '--event',
        'push',
        '--limit',
        '1',
        '--json',
        'databaseId,conclusion',
      ]),
    ) as List<dynamic>;
    if (runs.isEmpty || (runs.first as Map)['conclusion'] != 'success') {
      throw StateError('No successful push-triggered Checks run for $head.');
    }
    final runId = (runs.first as Map)['databaseId'] as int;
    final details = jsonDecode(query(['gh', 'run', 'view', '$runId', '--json', 'url,jobs'])) as Map<String, dynamic>;
    receipt['ciRunId'] = runId;
    receipt['ciRunUrl'] = details['url'] as String;
    log.writeln(jsonEncode(details));
    final jobs = (details['jobs'] as List<dynamic>).cast<Map<String, dynamic>>();
    for (final required in _ciJobs) {
      if (!jobs.any((job) => job['name'] == required && job['conclusion'] == 'success')) {
        throw StateError('Checks run $runId lacks a successful $required job.');
      }
    }
  }
}

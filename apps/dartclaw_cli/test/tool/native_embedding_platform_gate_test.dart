import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/native_embedding_platform_gate.dart';

void main() {
  test('observer accepts natural success and every natural expected failure', () async {
    final observer = NativeProbeObserver(
      runner: (executable, arguments, {required workingDirectory, required deadline, environment}) async {
        final failure = arguments.contains('--expect-failure');
        return ObservedCommand(
          exitCode: failure ? 1 : 0,
          stdoutText: jsonEncode({
            'result': failure ? 'expected-failure' : 'pass',
            if (failure) 'error': 'Native embedding initialization failed',
            if (!failure)
              'metrics': {
                'coldFirstEmbedMs': 10,
                'warmQueryMs': 2,
                'documentBatchMs': 3,
                'disposeMs': 1,
                'vectorDimension': 8,
                'documentCardinality': 2,
              },
          }),
          stderrText: '',
          elapsed: const Duration(milliseconds: 12),
          processExitObserved: true,
          forcedTermination: false,
        );
      },
    );
    final records = await observer.observe(_cases());
    expect(records.map((record) => record['operation']), [
      'success',
      'missingLibrary',
      'absentModel',
      'corruptModel',
      'nativeLoadFailure',
    ]);
    expect(records.every((record) => record['result'] == 'pass'), isTrue);
    expect(records.skip(1).every((record) => record['exitCode'] == 1), isTrue);
    expect(records.skip(1).every((record) => record['processExitObserved'] == true), isTrue);
  });

  test('malformed output, retained process and forced cleanup can never pass', () async {
    for (final result in [
      const ObservedCommand(
        exitCode: 0,
        stdoutText: 'not json',
        stderrText: '/Users/person/private/model.gguf',
        elapsed: Duration(milliseconds: 5),
        processExitObserved: true,
        forcedTermination: false,
      ),
      const ObservedCommand(
        exitCode: 0,
        stdoutText: '{"result":"pass"}',
        stderrText: '',
        elapsed: Duration(milliseconds: 5),
        processExitObserved: false,
        forcedTermination: false,
      ),
      const ObservedCommand(
        exitCode: 0,
        stdoutText: '{"result":"pass"}',
        stderrText: '',
        elapsed: Duration(seconds: 1),
        processExitObserved: true,
        forcedTermination: false,
        outputStreamsClosed: false,
      ),
      const ObservedCommand(
        exitCode: -1,
        stdoutText: '{"result":"pass"}',
        stderrText: '',
        elapsed: Duration(seconds: 90),
        processExitObserved: true,
        forcedTermination: true,
      ),
    ]) {
      final records = await NativeProbeObserver(
        runner: (executable, arguments, {required workingDirectory, required deadline, environment}) async => result,
      ).observe([_cases().first]);
      expect(records.single['result'], 'fail');
      expect('${records.single['sanitizedError']}', isNot(contains('/Users/person')));
    }
  });

  test('actual outer observer kills a stuck fake child and records forced termination', () async {
    final root = Directory.systemTemp.createTempSync('dartclaw-native-fake-child');
    addTearDown(() => root.deleteSync(recursive: true));
    final script = File(p.join(root.path, 'child.dart'))
      ..writeAsStringSync('Future<void> main() async => await Future<void>.delayed(const Duration(days: 1));\n');
    final result = await runObservedCommand(
      Platform.resolvedExecutable,
      [script.path],
      workingDirectory: root.path,
      deadline: const Duration(milliseconds: 100),
    );
    expect(result.forcedTermination, isTrue);
    expect(result.processExitObserved, isTrue);
  });

  test('outer observer escalates when a child ignores initial termination', () async {
    final root = Directory.systemTemp.createTempSync('dartclaw-native-resistant-child');
    addTearDown(() => root.deleteSync(recursive: true));
    final script = File(p.join(root.path, 'child.dart'))
      ..writeAsStringSync(
        "import 'dart:io';\n"
        'Future<void> main() async {\n'
        '  ProcessSignal.sigterm.watch().listen((_) {});\n'
        "  stdout.writeln('ready');\n"
        '  await Future<void>.delayed(const Duration(days: 1));\n'
        '}\n',
      );
    final result = await runObservedCommand(
      Platform.resolvedExecutable,
      [script.path],
      workingDirectory: root.path,
      deadline: const Duration(seconds: 1),
    );
    expect(result.stdoutText.trim(), 'ready');
    expect(result.forcedTermination, isTrue);
    expect(result.processExitObserved, isTrue);
    expect(result.outputStreamsClosed, isTrue);
    expect(result.exitCode, isNot(0));
    expect(result.elapsed, lessThan(const Duration(seconds: 13)));
  }, skip: Platform.isWindows ? 'Windows does not support ignoring SIGTERM' : false);

  test('inherited output pipes cannot retain an exited probe', () async {
    final root = Directory.systemTemp.createTempSync('dartclaw-native-retained-output');
    final pidFile = File(p.join(root.path, 'child.pid'));
    addTearDown(() {
      if (pidFile.existsSync()) Process.killPid(int.parse(pidFile.readAsStringSync()), ProcessSignal.sigkill);
      root.deleteSync(recursive: true);
    });
    final child = File(p.join(root.path, 'child.dart'))
      ..writeAsStringSync('Future<void> main() async => await Future<void>.delayed(const Duration(seconds: 30));\n');
    final script = File(p.join(root.path, 'parent.dart'))
      ..writeAsStringSync(
        "import 'dart:io';\n"
        'Future<void> main(List<String> args) async {\n'
        '  final child = await Process.start(Platform.resolvedExecutable, [args[0]], mode: ProcessStartMode.inheritStdio);\n'
        '  File(args[1]).writeAsStringSync(child.pid.toString());\n'
        '  exit(0);\n'
        '}\n',
      );
    final result = await runObservedCommand(
      Platform.resolvedExecutable,
      [script.path, child.path, pidFile.path],
      workingDirectory: root.path,
      deadline: const Duration(seconds: 3),
    );
    expect(result.exitCode, 0);
    expect(result.processExitObserved, isTrue);
    expect(result.outputStreamsClosed, isFalse);
    expect(result.elapsed, lessThan(const Duration(seconds: 5)));
  }, skip: Platform.isWindows ? 'POSIX inherited pipe fixture' : false);

  test('evidence schema accepts complete pass and failure records', () {
    final evidence = _validEvidence();
    expect(validateNativeEmbeddingEvidence(evidence), isTrue);

    evidence['result'] = 'fail';
    (evidence['linuxOpenMp'] as Map<String, Object?>)['resolved'] = false;
    final failure = (evidence['failureCases'] as List<Object?>).first as Map<String, Object?>;
    failure
      ..['processExitObserved'] = false
      ..['forcedTermination'] = true
      ..['outputStreamsClosed'] = false
      ..['result'] = 'fail';
    expect(validateNativeEmbeddingEvidence(evidence), isTrue);

    final windowsEvidence = _validEvidence();
    windowsEvidence['target'] = 'windows-x64';
    (windowsEvidence['platform'] as Map<String, Object?>)['os'] = 'windows';
    for (final archive in windowsEvidence['releaseArchives'] as List<Object?>) {
      final archiveMap = archive as Map<String, Object?>;
      archiveMap['basename'] = (archiveMap['basename'] as String).replaceFirst('linux-x64.tar.gz', 'windows-x64.zip');
    }
    windowsEvidence.remove('linuxOpenMp');
    expect(validateNativeEmbeddingEvidence(windowsEvidence), isTrue);
  });

  test('evidence schema rejects every missing or wrong-typed required field', () {
    final requiredPaths = <List<Object>>[
      for (final field in [
        'schemaVersion',
        'target',
        'sourceCommit',
        'platform',
        'dartVersion',
        'hardware',
        'nativeRelease',
        'model',
        'releaseArchives',
        'metrics',
        'linuxOpenMp',
        'failureCases',
        'result',
      ])
        [field],
      for (final field in ['os', 'architecture']) ['platform', field],
      ['hardware', 'processorCount'],
      for (final field in ['llamadart', 'release', 'archive', 'size', 'sha256', 'stagedSha256'])
        ['nativeRelease', field],
      for (final field in ['basename', 'size', 'sha256']) ['model', field],
      for (var archiveIndex = 0; archiveIndex < 2; archiveIndex++) ...[
        for (final field in ['basename', 'sha256', 'nativeLibraries']) ['releaseArchives', archiveIndex, field],
        for (var libraryIndex = 0; libraryIndex < 2; libraryIndex++)
          for (final field in ['path', 'sha256'])
            ['releaseArchives', archiveIndex, 'nativeLibraries', libraryIndex, field],
      ],
      for (final field in [
        'coldFirstEmbedMs',
        'warmQueryMs',
        'documentBatchMs',
        'disposeMs',
        'vectorDimension',
        'documentCardinality',
      ])
        ['metrics', field],
      for (final field in ['library', 'resolved']) ['linuxOpenMp', field],
      for (var failureIndex = 0; failureIndex < 4; failureIndex++)
        for (final field in [
          'operation',
          'elapsedMs',
          'sanitizedError',
          'exitCode',
          'processExitObserved',
          'forcedTermination',
          'outputStreamsClosed',
          'result',
        ])
          ['failureCases', failureIndex, field],
    ];

    for (final path in requiredPaths) {
      final missing = _validEvidence();
      _removeAtPath(missing, path);
      expect(validateNativeEmbeddingEvidence(missing), isFalse, reason: 'accepted missing ${path.join('.')}');

      final wrongType = _validEvidence();
      _setAtPath(wrongType, path, _wrongType(_valueAtPath(wrongType, path)));
      expect(validateNativeEmbeddingEvidence(wrongType), isFalse, reason: 'accepted wrong type at ${path.join('.')}');
    }
  });

  test('evidence schema rejects wrong cardinality, identity and result values', () {
    final mutations = <void Function(Map<String, Object?>)>[
      (evidence) => (evidence['releaseArchives'] as List<Object?>).removeLast(),
      (evidence) => ((evidence['releaseArchives'] as List<Object?>).first as Map<String, Object?>)['nativeLibraries'] =
          <Object?>[],
      (evidence) {
        final archives = evidence['releaseArchives'] as List<Object?>;
        (archives.last as Map<String, Object?>)['basename'] = (archives.first as Map<String, Object?>)['basename'];
      },
      (evidence) => ((evidence['releaseArchives'] as List<Object?>).first as Map<String, Object?>)['basename'] =
          'other-v0.26.0-linux-x64.tar.gz',
      (evidence) => (evidence['failureCases'] as List<Object?>).removeLast(),
      (evidence) {
        final failures = evidence['failureCases'] as List<Object?>;
        (failures.last as Map<String, Object?>)['operation'] = (failures.first as Map<String, Object?>)['operation'];
      },
      (evidence) =>
          ((evidence['failureCases'] as List<Object?>).first as Map<String, Object?>)['operation'] = 'unknown',
      (evidence) => ((evidence['failureCases'] as List<Object?>).first as Map<String, Object?>)['result'] = 'unknown',
      (evidence) => evidence['result'] = 'unknown',
      (evidence) => evidence['schemaVersion'] = '2',
      (evidence) => (evidence['linuxOpenMp'] as Map<String, Object?>)['library'] = 'other',
    ];
    for (final mutate in mutations) {
      final evidence = _validEvidence();
      mutate(evidence);
      expect(validateNativeEmbeddingEvidence(evidence), isFalse);
    }
  });

  test('linux failure probes select the exact FFI entry library', () {
    final selected = selectNativeLoaderLibrary([
      File('/release/lib/libllama-common.so'),
      File('/release/lib/libllamadart.so.0'),
      File('/release/lib/libllamadart.so'),
    ], operatingSystem: 'linux');

    expect(p.basename(selected.path), 'libllamadart.so');
    expect(
      () => selectNativeLoaderLibrary([
        File('/release/lib/libllama-common.so'),
        File('/release/lib/libllamadart.so.0'),
      ], operatingSystem: 'linux'),
      throwsStateError,
    );
  });

  test('probe proves document batch order with per-document production calls and never calls exit', () {
    final source = File(p.join(_repoRoot(), 'apps', 'dartclaw_cli', 'tool', 'native_embedding_probe.dart'))
        .readAsStringSync();
    expect(RegExp(r'embedDocuments\(documentInputs\)').allMatches(source), hasLength(1));
    expect(RegExp(r'embedDocuments\(\[documentInputs\.(?:first|last)\]\)').allMatches(source), hasLength(2));
    expect(RegExp(r'_requireSameVector\(documents\[[01]\]').allMatches(source), hasLength(2));
    expect(source, isNot(contains('exit(')));
  });
}

List<ProbeCase> _cases() => [
  for (final operation in ['success', 'missingLibrary', 'absentModel', 'corruptModel', 'nativeLoadFailure'])
    ProbeCase(
      operation: operation,
      executable: 'probe',
      workingDirectory: '.',
      arguments: operation == 'success' ? const [] : ['--expect-failure', operation],
      failure: operation != 'success',
    ),
];

String _repoRoot() {
  var current = Directory.current.absolute.path;
  while (!Directory(p.join(current, 'apps', 'dartclaw_cli')).existsSync()) {
    final parent = p.dirname(current);
    if (parent == current) throw StateError('Repository root not found');
    current = parent;
  }
  return current;
}

Map<String, Object?> _validEvidence() {
  final evidence = <String, Object?>{
    'schemaVersion': '1',
    'target': 'linux-x64',
    'sourceCommit': '0123456789abcdef',
    'platform': {'os': 'linux', 'architecture': 'x64'},
    'dartVersion': '3.13.0',
    'hardware': {'processorCount': 2},
    'nativeRelease': {
      'llamadart': '0.8.22',
      'release': 'v0.3.0',
      'archive': 'llamadart-native-linux-x64-v0.3.0.tar.gz',
      'size': 16,
      'sha256': 'native archive sha256',
      'stagedSha256': 'staged archive sha256',
    },
    'model': {'basename': 'model.gguf', 'size': 32, 'sha256': 'model sha256'},
    'releaseArchives': [
      for (final basename in ['dartclaw-v0.26.0-linux-x64.tar.gz', 'dartclaw-workflow-v0.26.0-linux-x64.tar.gz'])
        {
          'basename': basename,
          'sha256': 'release archive sha256',
          'nativeLibraries': [
            {'path': 'lib/libllamadart.so', 'sha256': 'llamadart sha256'},
            {'path': 'lib/libsqlite3.so', 'sha256': 'sqlite sha256'},
          ],
        },
    ],
    'metrics': {
      'coldFirstEmbedMs': 10,
      'warmQueryMs': 2,
      'documentBatchMs': 3,
      'disposeMs': 1,
      'vectorDimension': 8,
      'documentCardinality': 2,
    },
    'linuxOpenMp': {'library': 'libgomp.so.1', 'resolved': true},
    'failureCases': [
      for (final operation in ['missingLibrary', 'absentModel', 'corruptModel', 'nativeLoadFailure'])
        {
          'operation': operation,
          'elapsedMs': 1,
          'sanitizedError': 'safe',
          'exitCode': 1,
          'processExitObserved': true,
          'forcedTermination': false,
          'outputStreamsClosed': true,
          'result': 'pass',
        },
    ],
    'result': 'pass',
  };
  return jsonDecode(jsonEncode(evidence)) as Map<String, Object?>;
}

Object? _valueAtPath(Map<String, Object?> root, List<Object> path) {
  Object? value = root;
  for (final segment in path) {
    value = segment is String ? (value as Map<String, Object?>)[segment] : (value as List<Object?>)[segment as int];
  }
  return value;
}

void _removeAtPath(Map<String, Object?> root, List<Object> path) {
  final parent = _valueAtPath(root, path.sublist(0, path.length - 1)) as Map<String, Object?>;
  parent.remove(path.last as String);
}

void _setAtPath(Map<String, Object?> root, List<Object> path, Object? value) {
  final parent = _valueAtPath(root, path.sublist(0, path.length - 1));
  final key = path.last;
  if (key is String) {
    (parent as Map<String, Object?>)[key] = value;
  } else {
    (parent as List<Object?>)[key as int] = value;
  }
}

Object _wrongType(Object? value) => switch (value) {
  String() => 1,
  int() => 'not an integer',
  bool() => 'not a boolean',
  List<Object?>() || Map<String, Object?>() => false,
  _ => Object(),
};

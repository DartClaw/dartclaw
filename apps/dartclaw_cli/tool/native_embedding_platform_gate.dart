import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'native_artifact_preparation.dart';

typedef ObservedCommandRunner = Future<ObservedCommand> Function(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Duration deadline,
  Map<String, String>? environment,
});

final class ObservedCommand {
  const new({
    required this.exitCode,
    required this.stdoutText,
    required this.stderrText,
    required this.elapsed,
    required this.processExitObserved,
    required this.forcedTermination,
    this.outputStreamsClosed = true,
  });
  final int exitCode;
  final String stdoutText;
  final String stderrText;
  final Duration elapsed;
  final bool processExitObserved;
  final bool forcedTermination;
  final bool outputStreamsClosed;
}

final class ProbeCase {
  const new({
    required this.operation,
    required this.executable,
    required this.workingDirectory,
    required this.arguments,
    required this.failure,
  });
  final String operation;
  final String executable;
  final String workingDirectory;
  final List<String> arguments;
  final bool failure;
}

final class NativeProbeObserver {
  const new({ObservedCommandRunner runner = runObservedCommand}) : _runner = runner;
  final ObservedCommandRunner _runner;

  Future<List<Map<String, Object?>>> observe(List<ProbeCase> cases) async {
    final records = <Map<String, Object?>>[];
    for (final probeCase in cases) {
      final result = await _runner(
        probeCase.executable,
        probeCase.arguments,
        workingDirectory: probeCase.workingDirectory,
        deadline: probeCase.failure ? const Duration(seconds: 75) : const Duration(seconds: 90),
      );
      Map<String, Object?>? payload;
      try {
        final decoded = jsonDecode(result.stdoutText.trim());
        if (decoded is Map<String, Object?>) payload = decoded;
      } catch (_) {}
      final expectedResult = probeCase.failure ? 'expected-failure' : 'pass';
      final exitMatches = probeCase.failure ? result.exitCode != 0 : result.exitCode == 0;
      final passed =
          result.processExitObserved &&
          !result.forcedTermination &&
          result.outputStreamsClosed &&
          exitMatches &&
          payload?['result'] == expectedResult;
      records.add({
        'operation': probeCase.operation,
        'elapsedMs': result.elapsed.inMilliseconds,
        'sanitizedError': payload?['error'] is String
            ? _sanitize(payload!['error'] as String)
            : _sanitize(result.stderrText),
        'exitCode': result.exitCode,
        'processExitObserved': result.processExitObserved,
        'forcedTermination': result.forcedTermination,
        'outputStreamsClosed': result.outputStreamsClosed,
        'result': passed ? 'pass' : 'fail',
        if (!probeCase.failure && payload?['metrics'] is Map<String, Object?>) 'metrics': payload!['metrics'],
      });
    }
    return records;
  }
}

Future<ObservedCommand> runObservedCommand(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Duration deadline,
  Map<String, String>? environment,
}) async {
  final watch = Stopwatch()..start();
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: true,
  );
  final stdoutText = StringBuffer();
  final stderrText = StringBuffer();
  final stdoutDone = Completer<bool>();
  final stderrDone = Completer<bool>();
  StreamSubscription<String> collect(Stream<List<int>> stream, StringBuffer text, Completer<bool> done) => stream
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen(
        text.write,
        onDone: () => done.complete(true),
        onError: (Object error) {
          if (!done.isCompleted) done.complete(false);
        },
        cancelOnError: true,
      );
  final stdoutSubscription = collect(process.stdout, stdoutText, stdoutDone);
  final stderrSubscription = collect(process.stderr, stderrText, stderrDone);
  var forcedTermination = false;
  var processExitObserved = false;
  var outputStreamsClosed = false;
  int code;
  try {
    code = await process.exitCode.timeout(deadline);
    processExitObserved = true;
  } on TimeoutException {
    forcedTermination = true;
    process.kill();
    try {
      code = await process.exitCode.timeout(const Duration(seconds: 5));
      processExitObserved = true;
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      try {
        code = await process.exitCode.timeout(const Duration(seconds: 5));
        processExitObserved = true;
      } on TimeoutException {
        code = -1;
      }
    }
  }
  try {
    final closed = await Future.wait([stdoutDone.future, stderrDone.future]).timeout(const Duration(seconds: 1));
    outputStreamsClosed = closed.every((value) => value);
  } on TimeoutException {
    outputStreamsClosed = false;
  } finally {
    await Future.wait([stdoutSubscription.cancel(), stderrSubscription.cancel()]);
  }
  watch.stop();
  return ObservedCommand(
    exitCode: code,
    stdoutText: stdoutText.toString(),
    stderrText: stderrText.toString(),
    elapsed: watch.elapsed,
    processExitObserved: processExitObserved,
    forcedTermination: forcedTermination,
    outputStreamsClosed: outputStreamsClosed,
  );
}

Future<void> main(List<String> arguments) async {
  final target = _value(arguments, '--target');
  final evidencePath = _value(arguments, '--evidence');
  if (target == null || evidencePath == null) {
    stderr.writeln('Usage: native_embedding_platform_gate.dart --target <target> --evidence <path>');
    exitCode = 64;
    return;
  }
  if (!await NativeEmbeddingPlatformGate().run(target: target, evidencePath: evidencePath)) exitCode = 1;
}

final class NativeEmbeddingPlatformGate {
  new({NativeProbeObserver observer = const NativeProbeObserver()}) : _observer = observer;
  final NativeProbeObserver _observer;

  Future<bool> run({required String target, required String evidencePath}) async {
    final root = Directory.current.absolute;
    final outerStage = await Directory.systemTemp.createTemp('dartclaw-native-platform-gate-');
    Map<String, Object?> evidence;
    try {
      final manifestPath = _join(root.path, 'dev/native_artifacts.json');
      final manifest = await NativeArtifactManifest.load(manifestPath);
      final artifact = manifest.forTarget(target);
      final hostArchitecture = _hostArchitecture();
      if (target != '${Platform.operatingSystem}-$hostArchitecture') {
        throw StateError('Target $target requires a native $target runner');
      }
      final cache = Platform.environment['DARTCLAW_NATIVE_ARCHIVE_CACHE'];
      final modelPath = Platform.environment['DARTCLAW_EMBEDDING_MODEL_PATH'];
      if (cache == null || cache.isEmpty) throw StateError('DARTCLAW_NATIVE_ARCHIVE_CACHE is required');
      if (modelPath == null || modelPath.isEmpty) throw StateError('DARTCLAW_EMBEDDING_MODEL_PATH is required');
      await _verifyFile(File(modelPath), manifest.model.size, manifest.model.sha256, 'Embedding model');
      final preparation = await NativeArtifactPreparer().prepare(
        manifest: manifest,
        target: target,
        cacheDirectory: cache,
        stageParent: outerStage.path,
        allowDownload: false,
      );

      await _runReleaseBuild(root.path, target, cache, manifestPath);
      final version = _readVersion(root.path);
      final extension = Platform.isWindows ? 'zip' : 'tar.gz';
      final archiveNames = ['dartclaw-v$version-$target.$extension', 'dartclaw-workflow-v$version-$target.$extension'];
      final packages = <String, Directory>{};
      final packageEvidence = <Map<String, Object?>>[];
      for (final archiveName in archiveNames) {
        final archive = File(_joinAll(root.path, ['build', archiveName]));
        final extracted = Directory(_join(outerStage.path, archiveName.replaceAll('.', '-')));
        await extracted.create(recursive: true);
        final extraction = await Process.run('tar', ['-xf', archive.path, '-C', extracted.path]);
        if (extraction.exitCode != 0) throw StateError('Unable to extract release archive');
        final libraries = await _libraryManifest(extracted);
        packages[archiveName] = extracted;
        packageEvidence.add({'basename': archiveName, 'sha256': await _sha256(archive), 'nativeLibraries': libraries});
      }
      if (jsonEncode(packageEvidence[0]['nativeLibraries']) != jsonEncode(packageEvidence[1]['nativeLibraries'])) {
        throw StateError('Release archives contain different native library sets');
      }

      final probeWorkspace = _join(outerStage.path, 'probe-workspace');
      final stage = await Process.run('dart', [
        _join(root.path, 'dev/tools/stage_native_build_workspace.dart'),
        '--source',
        root.path,
        '--destination',
        probeWorkspace,
        '--hook-root',
        preparation.hookRoot,
        '--manifest',
        manifestPath,
      ], workingDirectory: root.path);
      if (stage.exitCode != 0) throw StateError('Native embedding probe workspace preparation failed');
      final resolve = await Process.run('dart', [
        'pub',
        'get',
        '--offline',
        '--enforce-lockfile',
      ], workingDirectory: probeWorkspace);
      if (resolve.exitCode != 0) throw StateError('Native embedding probe dependency resolution failed');
      final probeOutput = _join(outerStage.path, 'probe-build');
      final compile = await Process.run('dart', [
        'build',
        'cli',
        '-t',
        'tool/native_embedding_probe.dart',
        '-o',
        probeOutput,
      ], workingDirectory: _join(probeWorkspace, 'apps/dartclaw_cli'));
      if (compile.exitCode != 0) throw StateError('Native embedding probe compilation failed');
      final compiledProbe = File(
        _joinAll(probeOutput, ['bundle', 'bin', 'native_embedding_probe${Platform.isWindows ? '.exe' : ''}']),
      );

      final basePackage = packages[archiveNames.first]!;
      final loaderLibrary = selectNativeLoaderLibrary(await _nativeLibraryFiles(basePackage));
      final cases = <ProbeCase>[];
      for (final operation in ['success', 'missingLibrary', 'absentModel', 'corruptModel', 'nativeLoadFailure']) {
        final package = Directory(_join(outerStage.path, 'case-$operation'));
        await _copyDirectory(basePackage, package);
        final executable = File(_joinAll(package.path, ['bin', compiledProbe.uri.pathSegments.last]));
        await compiledProbe.copy(executable.path);
        var caseModelPath = modelPath;
        final packageLoader = File(_join(package.path, _relativePath(basePackage, loaderLibrary)));
        if (operation == 'missingLibrary') {
          await packageLoader.delete();
        } else if (operation == 'absentModel') {
          caseModelPath = _join(package.path, 'absent-model.gguf');
        } else if (operation == 'corruptModel') {
          caseModelPath = _join(package.path, 'corrupt-model.gguf');
          await File(caseModelPath).writeAsString('not a model');
        } else if (operation == 'nativeLoadFailure') {
          await packageLoader.writeAsString('invalid loader');
        }
        final failure = operation != 'success';
        cases.add(
          ProbeCase(
            operation: operation,
            executable: executable.path,
            workingDirectory: executable.parent.path,
            arguments: [
              '--model',
              caseModelPath,
              '--sha256',
              manifest.model.sha256,
              if (failure) ...['--expect-failure', operation],
            ],
            failure: failure,
          ),
        );
      }

      final records = await _observer.observe(cases);
      final success = records.first;
      final metrics = success['metrics'] is Map<String, Object?>
          ? success['metrics']! as Map<String, Object?>
          : <String, Object?>{};
      final timingPass =
          (metrics['coldFirstEmbedMs'] as int? ?? 60001) <= 60000 &&
          (metrics['disposeMs'] as int? ?? 10001) <= 10000 &&
          (metrics['vectorDimension'] as int? ?? 0) > 0 &&
          metrics['documentCardinality'] == 2;
      final linuxOpenMp = Platform.isLinux ? await _linuxOpenMpEvidence(loaderLibrary) : null;
      final passed =
          timingPass &&
          records.every((record) => record['result'] == 'pass') &&
          (linuxOpenMp == null || linuxOpenMp['resolved'] == true);
      evidence = {
        'schemaVersion': '1',
        'target': target,
        'sourceCommit': _sourceCommit(root.path),
        'platform': {'os': Platform.operatingSystem, 'architecture': hostArchitecture},
        'dartVersion': Platform.version.split('\n').first,
        'hardware': {'processorCount': Platform.numberOfProcessors},
        'nativeRelease': {
          'llamadart': '0.8.22',
          'release': manifest.release,
          'archive': artifact.archive,
          'size': artifact.size,
          'sha256': artifact.sha256,
          'stagedSha256': await _sha256(File(preparation.stagedArchive)),
        },
        'model': {
          'basename': File(modelPath).uri.pathSegments.last,
          'size': manifest.model.size,
          'sha256': manifest.model.sha256,
        },
        'releaseArchives': packageEvidence,
        'metrics': metrics,
        'successCase': success,
        'failureCases': records.skip(1).toList(),
        'linuxOpenMp': ?linuxOpenMp,
        'result': passed ? 'pass' : 'fail',
      };
      if (!validateNativeEmbeddingEvidence(evidence)) {
        evidence['result'] = 'fail';
        evidence['error'] = 'Native embedding evidence is incomplete';
      }
    } catch (error) {
      evidence = {'schemaVersion': '1', 'target': target, 'result': 'fail', 'error': _sanitize('$error')};
    }
    await _writeEvidence(File(evidencePath), evidence);
    try {
      await outerStage.delete(recursive: true);
    } catch (_) {}
    return evidence['result'] == 'pass';
  }
}

bool validateNativeEmbeddingEvidence(Map<String, Object?> evidence) {
  if (evidence case {
    'schemaVersion': '1',
    'target': String target,
    'sourceCommit': String _,
    'platform': {'os': String _, 'architecture': String _},
    'dartVersion': String _,
    'hardware': {'processorCount': int _},
    'nativeRelease': {
      'llamadart': String _,
      'release': String _,
      'archive': String _,
      'size': int _,
      'sha256': String _,
      'stagedSha256': String _,
    },
    'model': {'basename': String _, 'size': int _, 'sha256': String _},
    'metrics': {
      'coldFirstEmbedMs': int _,
      'warmQueryMs': int _,
      'documentBatchMs': int _,
      'disposeMs': int _,
      'vectorDimension': int _,
      'documentCardinality': int _,
    },
    'result': String result,
  }) {
    if (result != 'pass' && result != 'fail') return false;

    if (target.startsWith('linux-')) {
      final openMp = evidence['linuxOpenMp'];
      if (openMp is! Map<String, Object?> || openMp['library'] != 'libgomp.so.1' || openMp['resolved'] is! bool) {
        return false;
      }
    }

    final archives = evidence['releaseArchives'];
    final failures = evidence['failureCases'];
    if (archives is! List<Object?> || archives.length != 2 || failures is! List<Object?> || failures.length != 4) {
      return false;
    }

    final expectedArchiveSuffix = '-$target.${target.startsWith('windows-') ? 'zip' : 'tar.gz'}';
    final packageIdentities = <String>{};
    for (final value in archives) {
      if (value case {'basename': String basename, 'sha256': String _, 'nativeLibraries': List<Object?> libraries}) {
        final identity = basename.startsWith('dartclaw-workflow-v')
            ? 'dartclaw-workflow'
            : basename.startsWith('dartclaw-v')
            ? 'dartclaw'
            : null;
        if (identity == null || !basename.endsWith(expectedArchiveSuffix) || libraries.isEmpty) return false;
        packageIdentities.add(identity);
        for (final library in libraries) {
          if (library case {'path': String _, 'sha256': String _}) {
            continue;
          }
          return false;
        }
      } else {
        return false;
      }
    }
    if (packageIdentities.length != 2) return false;

    const operations = {'missingLibrary', 'absentModel', 'corruptModel', 'nativeLoadFailure'};
    final actualOperations = <String>{};
    for (final value in failures) {
      if (value case {
        'operation': String operation,
        'elapsedMs': int _,
        'sanitizedError': String _,
        'exitCode': int _,
        'processExitObserved': bool _,
        'forcedTermination': bool _,
        'outputStreamsClosed': bool _,
        'result': String result,
      }) {
        if ((result != 'pass' && result != 'fail') || !operations.contains(operation)) return false;
        actualOperations.add(operation);
      } else {
        return false;
      }
    }
    return actualOperations.length == operations.length;
  } else {
    return false;
  }
}

Future<void> _runReleaseBuild(String root, String target, String cache, String manifestPath) async {
  final environment = Map<String, String>.from(Platform.environment)
    ..['DARTCLAW_RELEASE_TARGET'] = target
    ..['DARTCLAW_NATIVE_ARCHIVE_CACHE'] = cache
    ..['DARTCLAW_NATIVE_MANIFEST'] = manifestPath;
  final result = await Process.run(
    releaseBuildShell(),
    Platform.isWindows
        ? ['-NoProfile', '-File', _join(root, 'dev/tools/build_windows.ps1'), '-ReleaseTarget', target]
        : [_join(root, 'dev/tools/build.sh')],
    workingDirectory: root,
    environment: environment,
  );
  if (result.exitCode != 0) throw StateError('Release build failed: ${_sanitize('${result.stderr}')}');
}

String releaseBuildShell({String? operatingSystem}) =>
    (operatingSystem ?? Platform.operatingSystem) == 'windows' ? 'pwsh' : 'bash';

String _hostArchitecture() {
  final result = Process.runSync(
    Platform.isWindows ? 'powershell' : 'uname',
    Platform.isWindows
        ? ['-NoProfile', '-Command', '[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()']
        : ['-m'],
  );
  final value = '${result.stdout}'.trim().toLowerCase();
  if (value == 'x86_64' || value == 'amd64') return 'x64';
  if (value == 'aarch64' || value == 'arm64') return 'arm64';
  return value;
}

Future<List<Map<String, Object?>>> _libraryManifest(Directory package) async {
  final libraryRoot = Directory(_join(package.path, 'lib'));
  if (!await libraryRoot.exists()) throw StateError('Release archive omitted native libraries');
  final files = await libraryRoot.list(recursive: true).where((entry) => entry is File).cast<File>().toList();
  files.sort((left, right) => left.path.compareTo(right.path));
  return [
    for (final file in files) {'path': _relativePath(package, file), 'sha256': await _sha256(file)},
  ];
}

Future<List<File>> _nativeLibraryFiles(Directory package) async {
  final files = await Directory(_join(package.path, 'lib'))
      .list(recursive: true)
      .where((entry) => entry is File)
      .cast<File>()
      .toList();
  final native = files.where((file) => !file.uri.pathSegments.last.toLowerCase().contains('sqlite')).toList();
  if (native.isEmpty) throw StateError('Release archive omitted llamadart native libraries');
  return native;
}

File selectNativeLoaderLibrary(List<File> files, {String? operatingSystem}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final basename = switch (os) {
    'windows' => 'llamadart.dll',
    'macos' => 'libllamadart.dylib',
    _ => 'libllamadart.so',
  };
  return files.firstWhere(
    (file) => file.uri.pathSegments.last.toLowerCase() == basename,
    orElse: () => throw StateError('Release archive omitted $basename'),
  );
}

Future<Map<String, Object?>> _linuxOpenMpEvidence(File loaderLibrary) async {
  final result = await Process.run('ldd', [loaderLibrary.path]);
  final line = const LineSplitter()
      .convert('${result.stdout}')
      .map((value) => value.trim())
      .where((value) => value.startsWith('libgomp.so.1'))
      .firstOrNull;
  return {'library': 'libgomp.so.1', 'resolved': result.exitCode == 0 && line != null && !line.contains('not found')};
}

Future<void> _verifyFile(File file, int size, String expectedSha256, String label) async {
  if (!await file.exists() || await file.length() != size || await _sha256(file) != expectedSha256) {
    throw StateError('$label verification failed');
  }
}

Future<String> _sha256(File file) async => (await sha256.bind(file.openRead()).first).toString();

String _readVersion(String root) {
  final source = File(_joinAll(root, ['packages', 'dartclaw_runtime', 'lib', 'src', 'version.dart']))
      .readAsStringSync();
  final match = RegExp("dartclawVersion = '([^']+)'").firstMatch(source);
  if (match == null) throw StateError('Unable to read DartClaw version');
  return match[1]!;
}

String _sourceCommit(String root) {
  final result = Process.runSync('git', ['-C', root, 'rev-parse', 'HEAD']);
  if (result.exitCode != 0) throw StateError('Unable to read source commit');
  return '${result.stdout}'.trim();
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final target = _join(destination.path, entity.uri.pathSegments.where((part) => part.isNotEmpty).last);
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(target));
    } else if (entity is File) {
      await entity.copy(target);
    }
  }
}

String _relativePath(Directory root, File file) => file.path.substring(root.path.length + 1).replaceAll('\\', '/');

Future<void> _writeEvidence(File destination, Map<String, Object?> evidence) async {
  await destination.parent.create(recursive: true);
  final temporary = File('${destination.path}.tmp-$pid');
  await temporary.writeAsString('${const JsonEncoder.withIndent('  ').convert(evidence)}\n', flush: true);
  if (await destination.exists()) await destination.delete();
  await temporary.rename(destination.path);
}

String _sanitize(String value) {
  var result = value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  result = result.replaceAll(RegExp(r'(?:[A-Za-z]:\\|/)[^ ]+'), '<path>');
  if (result.length > 300) result = result.substring(0, 300);
  return result;
}

String? _value(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) return null;
  return arguments[index + 1];
}

String _join(String first, String second) => '$first${Platform.pathSeparator}$second';
String _joinAll(String first, Iterable<String> rest) => rest.fold(first, _join);

extension on Iterable<String> {
  String? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_runtime/src/runtime/standalone_execution_lease.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('an unusable lock path reports the filesystem failure without claiming another owner', () async {
    final directory = Directory.systemTemp.createTempSync('dartclaw_standalone_bad_lock_');
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final lockPath = p.join(directory.path, 'execution.owner.lock');
    Directory(lockPath).createSync();

    await expectLater(
      StandaloneExecutionLease.acquire(directory.path),
      throwsA(
        isA<StandaloneExecutionLeaseException>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('Could not acquire standalone workflow execution lock'),
            contains(lockPath),
            isNot(contains('is already active for')),
          ),
        ),
      ),
    );

    Directory(lockPath).deleteSync();
    final lease = await StandaloneExecutionLease.acquire(directory.path);
    await lease.release();
  });

  test('the standalone execution lease refuses another process and releases for a later owner', () async {
    final directory = Directory.systemTemp.createTempSync('dartclaw_standalone_lease_');
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:dartclaw_runtime/src/runtime/standalone_execution_lease.dart'),
    );
    if (library == null) throw StateError('Could not resolve runtime package');
    final fixture = p.join(
      p.dirname(p.dirname(p.dirname(p.dirname(library.toFilePath())))),
      'test',
      'runtime',
      'fixtures',
      'standalone_lease_probe.dart',
    );
    final owner = await StandaloneExecutionLease.acquire(directory.path);
    final refused = await Process.run(Platform.resolvedExecutable, [fixture, directory.path]);
    expect(refused.exitCode, 3, reason: '${refused.stdout}\n${refused.stderr}');
    await owner.release();

    final later = await Process.run(Platform.resolvedExecutable, [fixture, directory.path]);
    expect(later.exitCode, 0, reason: '${later.stdout}\n${later.stderr}');
  });
}

import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/container/container_manager.dart';
import 'package:dartclaw_runtime/src/container/security_profile.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('container_manager_data_dir_mask_test_'));
  tearDown(() => temp.deleteSync(recursive: true));

  ContainerManager manager(List<String> workspaceMounts) => ContainerManager(
    ownerLabel: 'dartclaw.data-dir=/home/user/.dartclaw',
    config: const ContainerConfig(enabled: true),
    containerName: 'dartclaw-test1234-workspace',
    profileId: 'workspace',
    workspaceMounts: workspaceMounts,
    generatedStateDir: p.join(temp.path, 'state'),
    buildContextDir: temp.path,
    runCommand: (_, _) async => ProcessResult(1, 0, '', ''),
  );

  test('a host path under a masked data directory does not translate', () {
    final repo = p.join(temp.path, 'repo');
    final dataDir = p.join(repo, '.dartclaw-example');
    Directory(p.join(dataDir, 'workspace')).createSync(recursive: true);

    final masked = manager([
      '$repo:/project:ro',
      '/project/.dartclaw-example',
      '$dataDir/workspace:/workspace:rw',
      SecurityProfile.packageCachePath,
    ]);

    expect(masked.containerPathForHostPath(p.join(repo, 'lib')), '/project/lib');
    expect(masked.containerPathForHostPath(p.join(dataDir, 'workspace', 'x')), '/workspace/x');
    expect(masked.containerPathForHostPath(p.join(dataDir, 'credentials')), isNull);
    expect(masked.containerPathForHostPath(dataDir), isNull);

    final cacheOnly = manager(['$repo:/project:ro', SecurityProfile.packageCachePath]);
    expect(cacheOnly.containerPathForHostPath(p.join(repo, 'lib')), '/project/lib');
    expect(
      cacheOnly.containerPathForHostPath(p.join(dataDir, 'credentials')),
      '/project/.dartclaw-example/credentials',
    );
  });
}

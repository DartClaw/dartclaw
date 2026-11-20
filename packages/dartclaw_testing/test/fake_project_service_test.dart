import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('FakeProjectService', () {
    final registered = Project(
      id: 'registered',
      name: 'registered',
      remoteUrl: '',
      localPath: '/repos/registered',
      defaultBranch: 'main',
      status: ProjectStatus.ready,
      createdAt: DateTime.utc(2026),
    );

    test('has a _local project by default', () async {
      final service = FakeProjectService();

      expect(service.localProject?.id, '_local');
      expect((await service.get('_local'))?.id, '_local');
      expect((await service.defaultProject)?.id, '_local');
      expect((await service.getAll()).map((p) => p.id), ['_local']);
    });

    test('models a runtime with no local repository', () async {
      final service = FakeProjectService(hasLocalProject: false);

      expect(service.localProject, isNull);
      expect(await service.get('_local'), isNull);
      expect(await service.defaultProject, isNull);
      expect(await service.getAll(), isEmpty);

      service.seed(registered);
      expect((await service.defaultProject)?.id, 'registered');
      expect((await service.getAll()).map((p) => p.id), ['registered']);
    });
  });
}

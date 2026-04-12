import 'package:dartclaw_server/dartclaw_server.dart' show SecurityProfile;
import 'package:test/test.dart';

void main() {
  group('SecurityProfile.workspace()', () {
    test('without projectsClonesDir produces 2 mounts (backward compat)', () {
      final profile = SecurityProfile.workspace(workspaceDir: '/workspace', projectDir: '/project');
      expect(profile.workspaceMounts, hasLength(2));
      expect(profile.workspaceMounts, contains('/workspace:/workspace:rw'));
      expect(profile.workspaceMounts, contains('/project:/project:ro'));
    });

    test('with projectsClonesDir produces 3 mounts', () {
      final profile = SecurityProfile.workspace(
        workspaceDir: '/workspace',
        projectDir: '/project',
        projectsClonesDir: '/data/projects',
      );
      expect(profile.workspaceMounts, hasLength(3));
      expect(profile.workspaceMounts, contains('/workspace:/workspace:rw'));
      expect(profile.workspaceMounts, contains('/project:/project:ro'));
      expect(profile.workspaceMounts, contains('/data/projects:/projects:ro'));
    });

    test('mount paths use provided values', () {
      final profile = SecurityProfile.workspace(
        workspaceDir: '/custom/workspace',
        projectDir: '/custom/project',
        projectsClonesDir: '/custom/clones',
      );
      expect(profile.workspaceMounts[0], '/custom/workspace:/workspace:rw');
      expect(profile.workspaceMounts[1], '/custom/project:/project:ro');
      expect(profile.workspaceMounts[2], '/custom/clones:/projects:ro');
    });

    test('id is workspace and displayName is Workspace', () {
      final profile = SecurityProfile.workspace(workspaceDir: '/w', projectDir: '/p');
      expect(profile.id, 'workspace');
      expect(profile.displayName, 'Workspace');
    });

    test('null projectsClonesDir omits /projects mount', () {
      final withNull = SecurityProfile.workspace(workspaceDir: '/w', projectDir: '/p', projectsClonesDir: null);
      final withoutParam = SecurityProfile.workspace(workspaceDir: '/w', projectDir: '/p');
      expect(withNull.workspaceMounts, equals(withoutParam.workspaceMounts));
      expect(withNull.workspaceMounts.any((m) => m.contains('/projects:')), isFalse);
    });
  });

  group('SecurityProfile.restricted', () {
    test('has no workspace mounts', () {
      expect(SecurityProfile.restricted.workspaceMounts, isEmpty);
    });

    test('id is restricted', () {
      expect(SecurityProfile.restricted.id, 'restricted');
    });
  });
}

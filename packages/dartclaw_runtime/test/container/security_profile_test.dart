import 'package:dartclaw_runtime/dartclaw_runtime.dart' show SecurityProfile;
import 'package:test/test.dart';

void main() {
  group('SecurityProfile.workspace()', () {
    test('without projectsClonesDir produces the workspace bind mount and the package cache', () {
      final profile = SecurityProfile.workspace(workspaceDir: '/workspace');
      expect(profile.workspaceMounts, ['/workspace:/workspace:rw', SecurityProfile.packageCachePath]);
    });

    test('with projectsClonesDir adds the read-only /projects collection', () {
      final profile = SecurityProfile.workspace(workspaceDir: '/custom/workspace', projectsClonesDir: '/custom/clones');
      expect(profile.workspaceMounts, [
        '/custom/workspace:/workspace:rw',
        '/custom/clones:/projects:ro',
        SecurityProfile.packageCachePath,
      ]);
    });

    test('id is workspace and displayName is Workspace', () {
      final profile = SecurityProfile.workspace(workspaceDir: '/w');
      expect(profile.id, 'workspace');
      expect(profile.displayName, 'Workspace');
    });

    test('null projectsClonesDir omits /projects mount', () {
      final withNull = SecurityProfile.workspace(workspaceDir: '/w', projectsClonesDir: null);
      final withoutParam = SecurityProfile.workspace(workspaceDir: '/w');
      expect(withNull.workspaceMounts, equals(withoutParam.workspaceMounts));
      expect(withNull.workspaceMounts.any((m) => m.contains('/projects:')), isFalse);
    });

    test('an unconfigured agent receives no workspace mount', () {
      final profile = SecurityProfile.workspace(workspaceDir: null);

      expect(profile.workspaceMounts, [SecurityProfile.packageCachePath]);
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

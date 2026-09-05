import 'package:dartclaw_runtime/src/container/container_manager.dart';
import 'package:test/test.dart';

void main() {
  group('ContainerManager.generateName', () {
    test('S01: owner labels preserve data dirs even when name digests collide', () {
      const dataDirs = [
        '/home/user/.dartclaw',
        '/srv/dartclaw/dhjuh2ihju6y',
        '/srv/dartclaw/sn89rfo2rdpu',
        r'/srv/data dir/with=equals\and-backslash',
      ];
      for (final dataDir in dataDirs) {
        expect(ContainerManager.ownerLabel(dataDir), 'dartclaw.data-dir=$dataDir');
      }
      expect(ContainerManager.generateName(dataDirs[1], 'workspace'), 'dartclaw-f47f5131-workspace');
      expect(ContainerManager.generateName(dataDirs[2], 'workspace'), 'dartclaw-f47f5131-workspace');
      expect(ContainerManager.ownerLabel(dataDirs[1]), isNot(ContainerManager.ownerLabel(dataDirs[2])));
    });

    test('produces expected format', () {
      final name = ContainerManager.generateName('/home/user/.dartclaw', 'workspace');

      expect(name, matches(r'^dartclaw-[a-f0-9]{8}-workspace$'));
    });

    test('deterministic for same inputs', () {
      final first = ContainerManager.generateName('/home/user/.dartclaw', 'workspace');
      final second = ContainerManager.generateName('/home/user/.dartclaw', 'workspace');

      expect(first, second);
    });

    test('different data dirs produce different names', () {
      final first = ContainerManager.generateName('/home/a/.dartclaw', 'workspace');
      final second = ContainerManager.generateName('/home/b/.dartclaw', 'workspace');

      expect(first, isNot(second));
    });

    test('different profiles produce different names', () {
      final workspace = ContainerManager.generateName('/home/user/.dartclaw', 'workspace');
      final restricted = ContainerManager.generateName('/home/user/.dartclaw', 'restricted');

      expect(workspace, isNot(restricted));
    });

    test('name contains only safe Docker characters', () {
      final name = ContainerManager.generateName('/home/user/.dartclaw', 'restricted');

      expect(name, matches(r'^[a-z0-9-]+$'));
    });
  });
}

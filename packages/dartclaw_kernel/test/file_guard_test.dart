import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'guard_test_support.dart';

GuardContext _tool(String toolName, Map<String, dynamic> input) =>
    GuardContext(hookPoint: 'beforeToolCall', toolName: toolName, toolInput: input, timestamp: DateTime.now());

void main() {
  late FileGuard guard;

  setUp(() {
    guard = FileGuard();
  });

  group('FileGuard — no_access paths', () {
    test('blocks access to sensitive credential paths', () async {
      // .ssh and .aws are representative of the no_access category
      final ssh = await guard.evaluate(bashGuardContext('cat ~/.ssh/id_rsa'));
      expect(ssh.isBlock, isTrue);
      expect(ssh.message, contains('no_access'));

      expect((await guard.evaluate(bashGuardContext('cat ~/.aws/credentials'))).isBlock, isTrue);
    });
  });

  group('FileGuard — read_only paths', () {
    test('allows reading .env but blocks writing', () async {
      expect((await guard.evaluate(bashGuardContext('cat .env'))).isPass, isTrue);

      final write = await guard.evaluate(bashGuardContext('echo SECRET=x > .env'));
      expect(write.isBlock, isTrue);
      expect(write.message, contains('read_only'));
    });

    test('blocks deleting and in-place editing .env', () async {
      expect((await guard.evaluate(bashGuardContext('rm .env'))).isBlock, isTrue);
      expect((await guard.evaluate(bashGuardContext("sed -i 's/old/new/' .env"))).isBlock, isTrue);
    });

    test('blocks writing to credential file types', () async {
      // .pem, .key, .kube/config all share the same read_only mechanism
      expect((await guard.evaluate(bashGuardContext('echo cert > server.pem'))).isBlock, isTrue);
    });
  });

  group('FileGuard — no_delete paths', () {
    test('allows reading and writing .bashrc but blocks deleting', () async {
      expect((await guard.evaluate(bashGuardContext('cat ~/.bashrc'))).isPass, isTrue);
      expect((await guard.evaluate(bashGuardContext('echo alias >> ~/.bashrc'))).isPass, isTrue);

      final del = await guard.evaluate(bashGuardContext('rm ~/.bashrc'));
      expect(del.isBlock, isTrue);
      expect(del.message, contains('no_delete'));
    });
  });

  group('FileGuard — safe paths', () {
    test('allows safe path operations', () async {
      expect((await guard.evaluate(bashGuardContext('cat README.md'))).isPass, isTrue);
      expect((await guard.evaluate(bashGuardContext('echo hello > /tmp/test'))).isPass, isTrue);
      expect((await guard.evaluate(bashGuardContext('rm /tmp/test'))).isPass, isTrue);
    });
  });

  group('FileGuard — file_read tool', () {
    test('blocks file_read of a no_access path', () async {
      final home = Platform.environment['HOME'] ?? '/home/user';
      final v = await guard.evaluate(_tool('file_read', {'file_path': '$home/.ssh/id_rsa'}));
      expect(v.isBlock, isTrue);
      expect(v.message, contains('no_access'));
    });

    test('allows file_read of a read_only path', () async {
      expect((await guard.evaluate(_tool('file_read', {'file_path': '.env'}))).isPass, isTrue);
    });

    test('blocks file_write of a read_only path (regression guard)', () async {
      final v = await guard.evaluate(_tool('file_write', {'file_path': '.env'}));
      expect(v.isBlock, isTrue);
      expect(v.message, contains('read_only'));
    });
  });

  group('FileGuard — file_write / file_edit tools', () {
    test('blocks file_write to .ssh path and file_edit on .env', () async {
      final home = Platform.environment['HOME'] ?? '/home/user';
      expect((await guard.evaluate(_tool('file_write', {'file_path': '$home/.ssh/config'}))).isBlock, isTrue);
      expect((await guard.evaluate(_tool('file_edit', {'file_path': '.env'}))).isBlock, isTrue);
    });

    test('blocks file_edit notebook_path on a read-only notebook', () async {
      final v = await guard.evaluate(_tool('file_edit', {'notebook_path': '.env'}));
      expect(v.isBlock, isTrue);
      expect(v.message, contains('read_only'));
    });

    test('blocks later protected paths in multi-change payloads', () async {
      final v = await guard.evaluate(
        _tool('file_write', {
          'changes': [
            {'kind': 'update', 'path': '/tmp/benign.txt'},
            {'kind': 'update', 'path': '.env'},
          ],
        }),
      );

      expect(v.isBlock, isTrue);
      expect(v.message, contains('read_only'));
      expect(v.message, contains('.env'));
    });

    test('allows file_write to safe path', () async {
      final v = await guard.evaluate(_tool('file_write', {'file_path': '/tmp/test.txt'}));
      expect(v.isPass, isTrue);
    });
  });

  group('FileGuard — redirect parsing', () {
    test('blocks redirect to protected paths, allows redirect to /dev/null', () async {
      expect((await guard.evaluate(bashGuardContext('echo secret > .env'))).isBlock, isTrue);
      expect((await guard.evaluate(bashGuardContext('cmd >> server.key'))).isBlock, isTrue);
      expect((await guard.evaluate(bashGuardContext('cmd 2> /dev/null'))).isPass, isTrue);
    });
  });

  group('FileGuard — compound commands and cp/mv', () {
    test('blocks protected path access in compound command', () async {
      final home = Platform.environment['HOME'] ?? '/home/user';
      final v = await guard.evaluate(bashGuardContext('cat file && rm $home/.ssh/key'));
      expect(v.isBlock, isTrue);
    });

    test('blocks cp with protected destination', () async {
      final v = await guard.evaluate(bashGuardContext('cp secrets.txt .env'));
      expect(v.isBlock, isTrue);
    });

    test('resolves relative command paths from the provider working directory', () async {
      final tempDir = Directory.systemTemp.createTempSync('file_guard_cwd_test_');
      try {
        final protected = '${tempDir.path}/workspace/.env';
        final cwdGuard = FileGuard(
          config: FileGuardConfig(
            rules: [FileGuardRule(pattern: protected, level: FileAccessLevel.readOnly)],
          ),
        );
        final verdict = await cwdGuard.evaluate(
          _tool('shell', {'command': 'echo secret > .env', 'cwd': p.dirname(protected)}),
        );

        expect(verdict.isBlock, isTrue);
        expect(verdict.message, contains(protected));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('FileGuard — non-applicable hooks', () {
    test('passes for non-beforeToolCall hook and non-file tools', () async {
      final ctx = GuardContext(hookPoint: 'messageReceived', messageContent: 'hello', timestamp: DateTime.now());
      expect((await guard.evaluate(ctx)).isPass, isTrue);

      expect((await guard.evaluate(_tool('web_fetch', {'url': 'https://example.com'}))).isPass, isTrue);
    });
  });

  group('FileGuard — config self-protection', () {
    test('blocks writing to protected config path', () async {
      final configGuard = FileGuard(config: FileGuardConfig.defaults().withSelfProtection('/etc/dartclaw.yaml'));
      final v = await configGuard.evaluate(_tool('file_write', {'file_path': '/etc/dartclaw.yaml'}));
      expect(v.isBlock, isTrue);
    });
  });

  group('FileGuard — symlink resolution', () {
    test('resolves symlink to protected path', () async {
      final tempDir = Directory.systemTemp.createTempSync('file_guard_test_');
      try {
        final targetDir = Directory('${tempDir.path}/.ssh');
        targetDir.createSync();
        File('${targetDir.path}/id_rsa').writeAsStringSync('secret');
        final link = Link('${tempDir.path}/link_to_ssh');
        link.createSync('${targetDir.path}/id_rsa');

        final customGuard = FileGuard(
          config: FileGuardConfig(
            rules: [FileGuardRule(pattern: '${targetDir.path}/id_rsa', level: FileAccessLevel.noAccess)],
          ),
        );
        final v = await customGuard.evaluate(bashGuardContext('cat ${link.path}'));
        expect(v.isBlock, isTrue);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('FileGuardConfig', () {
    test('defaults has non-empty rules', () {
      expect(FileGuardConfig.defaults().rules, isNotEmpty);
    });

    test('fromYaml merges extra_rules and ignores malformed rules', () {
      final merged = FileGuardConfig.fromYaml({
        'extra_rules': [
          {'pattern': '**/.custom', 'level': 'no_access'},
        ],
      });
      expect(merged.rules.length, FileGuardConfig.defaults().rules.length + 1);

      final malformed = FileGuardConfig.fromYaml({
        'extra_rules': [
          {'pattern': '**/.custom'}, // missing level
          {'level': 'no_access'}, // missing pattern
          {'pattern': '**/.x', 'level': 'invalid_level'}, // invalid level
        ],
      });
      expect(malformed.rules.length, FileGuardConfig.defaults().rules.length);
    });
  });

  group('FileGuard — glob matching', () {
    test('**/.env matches .env and subdir/.env', () async {
      expect((await guard.evaluate(bashGuardContext('echo x > .env'))).isBlock, isTrue);
      expect((await guard.evaluate(bashGuardContext('echo x > subdir/.env'))).isBlock, isTrue);
    });

    test('**/*.pem matches cert.pem at root and in subdirs', () async {
      expect((await guard.evaluate(bashGuardContext('echo x > cert.pem'))).isBlock, isTrue);
      expect((await guard.evaluate(bashGuardContext('echo x > dir/cert.pem'))).isBlock, isTrue);
    });

    // `**/` is anchored to a segment boundary, so a directory whose name merely
    // ends in the guarded one is not the guarded one. Before the shared
    // compiler, `**` compiled to a bare `.*` here and `user.ssh/` matched.
    test('**/.ssh/** is anchored to a segment boundary', () async {
      expect((await guard.evaluate(bashGuardContext('cat /home/u/.ssh/id_rsa'))).isBlock, isTrue);
      expect((await guard.evaluate(bashGuardContext('cat /home/user.ssh/id_rsa'))).isBlock, isFalse);
    });

    // An operator rule using brace alternation used to compile the braces as
    // literals, so the rule silently never matched and the paths it named went
    // unguarded.
    test('a rule using brace alternation matches either alternative', () async {
      final braced = FileGuard(
        config: FileGuardConfig.fromYaml({
          'extra_rules': [
            {'pattern': '**/*.{secret,token}', 'level': 'no_access'},
          ],
        }),
      );

      expect((await braced.evaluate(bashGuardContext('cat app/db.secret'))).isBlock, isTrue);
      expect((await braced.evaluate(bashGuardContext('cat app/api.token'))).isBlock, isTrue);
      expect((await braced.evaluate(bashGuardContext('cat app/notes.md'))).isBlock, isFalse);
    });
  });
}

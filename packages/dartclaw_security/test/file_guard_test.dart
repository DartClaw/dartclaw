import 'dart:io';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:test/test.dart';

GuardContext _bash(String command) => GuardContext(
  hookPoint: 'beforeToolCall',
  toolName: 'Bash',
  toolInput: {'command': command},
  timestamp: DateTime.now(),
);

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
      final ssh = await guard.evaluate(_bash('cat ~/.ssh/id_rsa'));
      expect(ssh.isBlock, isTrue);
      expect(ssh.message, contains('no_access'));

      expect((await guard.evaluate(_bash('cat ~/.aws/credentials'))).isBlock, isTrue);
    });
  });

  group('FileGuard — read_only paths', () {
    test('allows reading .env but blocks writing', () async {
      expect((await guard.evaluate(_bash('cat .env'))).isPass, isTrue);

      final write = await guard.evaluate(_bash('echo SECRET=x > .env'));
      expect(write.isBlock, isTrue);
      expect(write.message, contains('read_only'));
    });

    test('blocks deleting and in-place editing .env', () async {
      expect((await guard.evaluate(_bash('rm .env'))).isBlock, isTrue);
      expect((await guard.evaluate(_bash("sed -i 's/old/new/' .env"))).isBlock, isTrue);
    });

    test('blocks writing to credential file types', () async {
      // .pem, .key, .kube/config all share the same read_only mechanism
      expect((await guard.evaluate(_bash('echo cert > server.pem'))).isBlock, isTrue);
    });
  });

  group('FileGuard — no_delete paths', () {
    test('allows reading and writing .bashrc but blocks deleting', () async {
      expect((await guard.evaluate(_bash('cat ~/.bashrc'))).isPass, isTrue);
      expect((await guard.evaluate(_bash('echo alias >> ~/.bashrc'))).isPass, isTrue);

      final del = await guard.evaluate(_bash('rm ~/.bashrc'));
      expect(del.isBlock, isTrue);
      expect(del.message, contains('no_delete'));
    });
  });

  group('FileGuard — safe paths', () {
    test('allows safe path operations', () async {
      expect((await guard.evaluate(_bash('cat README.md'))).isPass, isTrue);
      expect((await guard.evaluate(_bash('echo hello > /tmp/test'))).isPass, isTrue);
      expect((await guard.evaluate(_bash('rm /tmp/test'))).isPass, isTrue);
    });
  });

  group('FileGuard — write_file / edit_file tools', () {
    test('blocks write_file to .ssh path and edit_file on .env', () async {
      final home = Platform.environment['HOME'] ?? '/home/user';
      expect((await guard.evaluate(_tool('write_file', {'file_path': '$home/.ssh/config'}))).isBlock, isTrue);
      expect((await guard.evaluate(_tool('edit_file', {'file_path': '.env'}))).isBlock, isTrue);
    });

    test('allows write_file to safe path', () async {
      final v = await guard.evaluate(_tool('write_file', {'file_path': '/tmp/test.txt'}));
      expect(v.isPass, isTrue);
    });
  });

  group('FileGuard — redirect parsing', () {
    test('blocks redirect to protected paths, allows redirect to /dev/null', () async {
      expect((await guard.evaluate(_bash('echo secret > .env'))).isBlock, isTrue);
      expect((await guard.evaluate(_bash('cmd >> server.key'))).isBlock, isTrue);
      expect((await guard.evaluate(_bash('cmd 2> /dev/null'))).isPass, isTrue);
    });
  });

  group('FileGuard — compound commands and cp/mv', () {
    test('blocks protected path access in compound command', () async {
      final home = Platform.environment['HOME'] ?? '/home/user';
      final v = await guard.evaluate(_bash('cat file && rm $home/.ssh/key'));
      expect(v.isBlock, isTrue);
    });

    test('blocks cp with protected destination', () async {
      final v = await guard.evaluate(_bash('cp secrets.txt .env'));
      expect(v.isBlock, isTrue);
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
      final v = await configGuard.evaluate(_tool('write_file', {'file_path': '/etc/dartclaw.yaml'}));
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
        final v = await customGuard.evaluate(_bash('cat ${link.path}'));
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
      expect((await guard.evaluate(_bash('echo x > .env'))).isBlock, isTrue);
      expect((await guard.evaluate(_bash('echo x > subdir/.env'))).isBlock, isTrue);
    });

    test('**/*.pem matches cert.pem at root and in subdirs', () async {
      expect((await guard.evaluate(_bash('echo x > cert.pem'))).isBlock, isTrue);
      expect((await guard.evaluate(_bash('echo x > dir/cert.pem'))).isBlock, isTrue);
    });
  });
}

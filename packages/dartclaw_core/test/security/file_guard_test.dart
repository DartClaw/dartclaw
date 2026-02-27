import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

GuardContext _bash(String command) => GuardContext(
  hookPoint: 'beforeToolCall',
  toolName: 'Bash',
  toolInput: {'command': command},
  timestamp: DateTime.now(),
);

GuardContext _tool(String toolName, Map<String, dynamic> input) => GuardContext(
  hookPoint: 'beforeToolCall',
  toolName: toolName,
  toolInput: input,
  timestamp: DateTime.now(),
);

void main() {
  late FileGuard guard;

  setUp(() {
    guard = FileGuard();
  });

  group('FileGuard — no_access paths', () {
    test('blocks read of .ssh/id_rsa', () async {
      final v = await guard.evaluate(_bash('cat ~/.ssh/id_rsa'));
      expect(v.isBlock, isTrue);
      expect(v.message, contains('no_access'));
    });

    test('blocks write to .ssh/', () async {
      final v = await guard.evaluate(_bash('echo key > ~/.ssh/authorized_keys'));
      expect(v.isBlock, isTrue);
    });

    test('blocks access to .gnupg', () async {
      final v = await guard.evaluate(_bash('cat ~/.gnupg/secring.gpg'));
      expect(v.isBlock, isTrue);
    });

    test('blocks access to .aws/credentials', () async {
      final v = await guard.evaluate(_bash('cat ~/.aws/credentials'));
      expect(v.isBlock, isTrue);
    });

    test('blocks access to .netrc', () async {
      final v = await guard.evaluate(_bash('cat ~/.netrc'));
      expect(v.isBlock, isTrue);
    });
  });

  group('FileGuard — read_only paths', () {
    test('allows reading .env', () async {
      final v = await guard.evaluate(_bash('cat .env'));
      expect(v.isPass, isTrue);
    });

    test('blocks writing to .env', () async {
      final v = await guard.evaluate(_bash('echo SECRET=x > .env'));
      expect(v.isBlock, isTrue);
      expect(v.message, contains('read_only'));
    });

    test('blocks deleting .env', () async {
      final v = await guard.evaluate(_bash('rm .env'));
      expect(v.isBlock, isTrue);
    });

    test('blocks sed -i on .env', () async {
      final v = await guard.evaluate(_bash("sed -i 's/old/new/' .env"));
      expect(v.isBlock, isTrue);
    });

    test('allows sed (without -i) on .env', () async {
      final v = await guard.evaluate(_bash("sed 's/old/new/' .env"));
      // sed without -i is read — but .env is first non-flag arg which is the expression
      // Actually our parser skips the first non-flag arg (the sed expression)
      // and treats subsequent args as paths. So 'sed s/old/new/ .env' → path=.env, op=read
      expect(v.isPass, isTrue);
    });

    test('blocks writing to .pem file', () async {
      final v = await guard.evaluate(_bash('echo cert > server.pem'));
      expect(v.isBlock, isTrue);
    });

    test('blocks writing to .key file', () async {
      final v = await guard.evaluate(_bash('touch private.key'));
      expect(v.isBlock, isTrue);
    });

    test('blocks writing to .kube/config', () async {
      final v = await guard.evaluate(_bash('echo ctx > ~/.kube/config'));
      expect(v.isBlock, isTrue);
    });
  });

  group('FileGuard — no_delete paths', () {
    test('allows reading .bashrc', () async {
      final v = await guard.evaluate(_bash('cat ~/.bashrc'));
      expect(v.isPass, isTrue);
    });

    test('allows writing to .bashrc (no_delete permits write)', () async {
      final v = await guard.evaluate(_bash('echo alias >> ~/.bashrc'));
      // redirect >> → write, .bashrc is no_delete → write is allowed
      expect(v.isPass, isTrue);
    });

    test('blocks deleting .bashrc', () async {
      final v = await guard.evaluate(_bash('rm ~/.bashrc'));
      expect(v.isBlock, isTrue);
      expect(v.message, contains('no_delete'));
    });

    test('blocks deleting .zshrc', () async {
      final v = await guard.evaluate(_bash('rm ~/.zshrc'));
      expect(v.isBlock, isTrue);
    });
  });

  group('FileGuard — safe paths', () {
    test('allows cat README.md', () async {
      final v = await guard.evaluate(_bash('cat README.md'));
      expect(v.isPass, isTrue);
    });

    test('allows echo > /tmp/test', () async {
      final v = await guard.evaluate(_bash('echo hello > /tmp/test'));
      expect(v.isPass, isTrue);
    });

    test('allows rm /tmp/test', () async {
      final v = await guard.evaluate(_bash('rm /tmp/test'));
      expect(v.isPass, isTrue);
    });
  });

  group('FileGuard — write_file / edit_file tools', () {
    test('blocks write_file to .ssh path', () async {
      final home = Platform.environment['HOME'] ?? '/home/user';
      final v = await guard.evaluate(_tool('write_file', {'file_path': '$home/.ssh/config'}));
      expect(v.isBlock, isTrue);
    });

    test('blocks edit_file on .env', () async {
      final v = await guard.evaluate(_tool('edit_file', {'file_path': '.env'}));
      expect(v.isBlock, isTrue);
    });

    test('allows write_file to safe path', () async {
      final v = await guard.evaluate(_tool('write_file', {'file_path': '/tmp/test.txt'}));
      expect(v.isPass, isTrue);
    });
  });

  group('FileGuard — redirect parsing', () {
    test('blocks echo > .env', () async {
      final v = await guard.evaluate(_bash('echo secret > .env'));
      expect(v.isBlock, isTrue);
    });

    test('blocks >> append to .key file', () async {
      final v = await guard.evaluate(_bash('cmd >> server.key'));
      expect(v.isBlock, isTrue);
    });

    test('allows redirect to /dev/null', () async {
      final v = await guard.evaluate(_bash('cmd 2> /dev/null'));
      expect(v.isPass, isTrue);
    });
  });

  group('FileGuard — compound commands', () {
    test('blocks rm in compound command', () async {
      final home = Platform.environment['HOME'] ?? '/home/user';
      final v = await guard.evaluate(_bash('cat file && rm $home/.ssh/key'));
      expect(v.isBlock, isTrue);
    });
  });

  group('FileGuard — cp/mv', () {
    test('blocks cp destination to .env', () async {
      final v = await guard.evaluate(_bash('cp secrets.txt .env'));
      expect(v.isBlock, isTrue);
    });
  });

  group('FileGuard — non-applicable hooks', () {
    test('passes for non-beforeToolCall hook', () async {
      final ctx = GuardContext(
        hookPoint: 'messageReceived',
        messageContent: 'hello',
        timestamp: DateTime.now(),
      );
      expect((await guard.evaluate(ctx)).isPass, isTrue);
    });

    test('passes for non-file tools', () async {
      final v = await guard.evaluate(_tool('web_fetch', {'url': 'https://example.com'}));
      expect(v.isPass, isTrue);
    });
  });

  group('FileGuard — config self-protection', () {
    test('blocks writing to protected config path', () async {
      final configGuard = FileGuard(
        config: FileGuardConfig.defaults().withSelfProtection('/etc/dartclaw.yaml'),
      );
      final v = await configGuard.evaluate(_tool('write_file', {'file_path': '/etc/dartclaw.yaml'}));
      expect(v.isBlock, isTrue);
    });
  });

  group('FileGuard — symlink resolution', () {
    test('resolves symlink to protected path', () async {
      // Create temp dir with symlink
      final tempDir = Directory.systemTemp.createTempSync('file_guard_test_');
      try {
        final targetDir = Directory('${tempDir.path}/.ssh');
        targetDir.createSync();
        File('${targetDir.path}/id_rsa').writeAsStringSync('secret');
        final link = Link('${tempDir.path}/link_to_ssh');
        link.createSync('${targetDir.path}/id_rsa');

        final customGuard = FileGuard(
          config: FileGuardConfig(rules: [
            FileGuardRule(pattern: '${targetDir.path}/id_rsa', level: FileAccessLevel.noAccess),
          ]),
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

    test('fromYaml with empty map uses defaults', () {
      final cfg = FileGuardConfig.fromYaml({});
      expect(cfg.rules.length, FileGuardConfig.defaults().rules.length);
    });

    test('fromYaml merges extra_rules', () {
      final cfg = FileGuardConfig.fromYaml({
        'extra_rules': [
          {'pattern': '**/.custom', 'level': 'no_access'},
        ],
      });
      expect(cfg.rules.length, FileGuardConfig.defaults().rules.length + 1);
    });

    test('fromYaml ignores malformed rules', () {
      final cfg = FileGuardConfig.fromYaml({
        'extra_rules': [
          {'pattern': '**/.custom'}, // missing level
          {'level': 'no_access'}, // missing pattern
          {'pattern': '**/.x', 'level': 'invalid_level'}, // invalid level
        ],
      });
      expect(cfg.rules.length, FileGuardConfig.defaults().rules.length);
    });
  });

  group('FileGuard — glob matching', () {
    test('**/.env matches .env', () async {
      final v = await guard.evaluate(_bash('echo x > .env'));
      expect(v.isBlock, isTrue);
    });

    test('**/.env matches subdir/.env', () async {
      final v = await guard.evaluate(_bash('echo x > subdir/.env'));
      expect(v.isBlock, isTrue);
    });

    test('**/*.pem matches cert.pem', () async {
      final v = await guard.evaluate(_bash('echo x > cert.pem'));
      expect(v.isBlock, isTrue);
    });

    test('**/*.pem matches dir/cert.pem', () async {
      final v = await guard.evaluate(_bash('echo x > dir/cert.pem'));
      expect(v.isBlock, isTrue);
    });
  });
}

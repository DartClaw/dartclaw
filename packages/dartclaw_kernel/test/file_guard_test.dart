import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'guard_test_support.dart';

GuardContext _tool(String toolName, Map<String, dynamic> input) =>
    GuardContext(hookPoint: 'beforeToolCall', toolName: toolName, toolInput: input, timestamp: DateTime.now());

GuardContext _search(String rawToolName, Map<String, dynamic> input) => GuardContext(
  hookPoint: 'beforeToolCall',
  toolName: 'file_read',
  rawProviderToolName: rawToolName,
  toolInput: input,
  timestamp: DateTime.now(),
);

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

  // Reading these sends the secret to the provider, whatever process or
  // container boundary the harness runs behind.
  group('FileGuard — credential files', () {
    const credentialPaths = [
      '.env',
      'config/.env.production',
      'certs/server.pem',
      'client.p12',
      'client.pfx',
      'keys/id_rsa',
      'id_dsa',
      'id_ecdsa',
      'deploy/id_ed25519.pub',
    ];

    test('blocks reading every default credential file type', () async {
      for (final path in credentialPaths) {
        final read = await guard.evaluate(_tool('file_read', {'file_path': path}));
        expect(read.isBlock, isTrue, reason: path);
        expect(read.message, contains('no_access'), reason: path);
        expect((await guard.evaluate(bashGuardContext('cat $path'))).isBlock, isTrue, reason: path);
      }
    });

    test('leaves .env templates readable and writable', () async {
      for (final path in ['.env.example', 'app/.env.sample', '.env.template', '.env.dist']) {
        expect((await guard.evaluate(_tool('file_read', {'file_path': path}))).isPass, isTrue, reason: path);
        expect((await guard.evaluate(_tool('file_write', {'file_path': path}))).isPass, isTrue, reason: path);
      }
    });

    test('an operator allow rule re-admits a default path and nothing else', () async {
      final relaxed = FileGuard(
        config: FileGuardConfig.fromYaml({
          'extra_rules': [
            {'pattern': '**/.env', 'level': 'allow'},
          ],
        }),
      );
      expect((await relaxed.evaluate(_tool('file_read', {'file_path': '.env'}))).isPass, isTrue);
      expect((await relaxed.evaluate(_tool('file_read', {'file_path': '.env.production'}))).isBlock, isTrue);
      expect((await relaxed.evaluate(bashGuardContext('cat ~/.ssh/id_rsa'))).isBlock, isTrue);
    });
  });

  group('FileGuard — read_only paths', () {
    test('allows reading a .key file but blocks writing', () async {
      expect((await guard.evaluate(bashGuardContext('cat tls/server.key'))).isPass, isTrue);

      final write = await guard.evaluate(bashGuardContext('echo x > tls/server.key'));
      expect(write.isBlock, isTrue);
      expect(write.message, contains('read_only'));
    });

    test('blocks deleting and in-place editing a .key file', () async {
      expect((await guard.evaluate(bashGuardContext('rm server.key'))).isBlock, isTrue);
      expect((await guard.evaluate(bashGuardContext("sed -i 's/old/new/' server.key"))).isBlock, isTrue);
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
      expect((await guard.evaluate(_tool('file_read', {'file_path': 'server.key'}))).isPass, isTrue);
    });

    test('blocks file_write of a read_only path (regression guard)', () async {
      final v = await guard.evaluate(_tool('file_write', {'file_path': 'server.key'}));
      expect(v.isBlock, isTrue);
      expect(v.message, contains('read_only'));
    });
  });

  // Claude Code's Grep and Glob are checked on the directory they search, as
  // Claude's own Read deny rules are; enumeration below an allowed root is left
  // to harness-native rules and OS sandboxes (ADR-061).
  group('FileGuard — search tools', () {
    late String ws;

    setUp(() {
      ws = Directory.systemTemp.createTempSync('file_guard_search_test_').resolveSymbolicLinksSync();
      Directory('$ws/.ssh').createSync();
      File('$ws/.ssh/id_rsa').writeAsStringSync('secret');
      Directory('$ws/proj').createSync();
      File('$ws/proj/main.dart').writeAsStringSync('void main() {}');
      File('$ws/proj/.env').writeAsStringSync('API_KEY=x');
    });

    tearDown(() => Directory(ws).deleteSync(recursive: true));

    test('blocks a search rooted at or inside a no_access path', () async {
      final v = await guard.evaluate(_search('Grep', {'pattern': 'PRIVATE KEY', 'path': '$ws/.ssh'}));
      expect(v.isBlock, isTrue);
      expect(v.message, contains('no_access'));
      expect((await guard.evaluate(_search('Glob', {'pattern': '*', 'path': '$ws/.ssh/keys'}))).isBlock, isTrue);
      expect((await guard.evaluate(_search('Grep', {'pattern': 'KEY', 'path': '~/.ssh'}))).isBlock, isTrue);
      expect((await guard.evaluate(_search('Grep', {'pattern': 'KEY', 'path': '$ws/proj/.env'}))).isBlock, isTrue);
    });

    test('allows a search whose root merely holds a protected file', () async {
      expect((await guard.evaluate(_search('Grep', {'pattern': 'API_KEY', 'path': '$ws/proj'}))).isPass, isTrue);
      expect((await guard.evaluate(_search('Glob', {'pattern': '**/id_*', 'path': ws}))).isPass, isTrue);
    });

    test('resolves an absent or relative root from the tool cwd', () async {
      expect((await guard.evaluate(_search('Grep', {'pattern': 'KEY', 'cwd': '$ws/.ssh'}))).isBlock, isTrue);
      final rel = await guard.evaluate(_search('Grep', {'pattern': 'KEY', 'path': '../.ssh', 'cwd': '$ws/proj'}));
      expect(rel.isBlock, isTrue);
      expect(
        (await guard.evaluate(_search('Grep', {'pattern': 'KEY', 'path': '.env', 'cwd': '$ws/proj'}))).isBlock,
        isTrue,
      );
      expect((await guard.evaluate(_search('Grep', {'pattern': 'KEY', 'cwd': '$ws/proj'}))).isPass, isTrue);
    });

    test("does not read Grep's content regex or Glob's pattern as a path", () async {
      expect((await guard.evaluate(_search('Grep', {'pattern': '.ssh/id_rsa', 'path': '$ws/proj'}))).isPass, isTrue);
      expect((await guard.evaluate(_search('Glob', {'pattern': '**/.env', 'path': '$ws/proj'}))).isPass, isTrue);
    });
  });

  group('FileGuard — file_write / file_edit tools', () {
    test('blocks file_write to .ssh path and file_edit on .env', () async {
      final home = Platform.environment['HOME'] ?? '/home/user';
      expect((await guard.evaluate(_tool('file_write', {'file_path': '$home/.ssh/config'}))).isBlock, isTrue);
      expect((await guard.evaluate(_tool('file_edit', {'file_path': '.env'}))).isBlock, isTrue);
    });

    test('blocks file_edit notebook_path on a read-only notebook', () async {
      final v = await guard.evaluate(_tool('file_edit', {'notebook_path': 'server.key'}));
      expect(v.isBlock, isTrue);
      expect(v.message, contains('read_only'));
    });

    test('blocks later protected paths in multi-change payloads', () async {
      final v = await guard.evaluate(
        _tool('file_write', {
          'changes': [
            {'kind': 'update', 'path': '/tmp/benign.txt'},
            {'kind': 'update', 'path': 'server.key'},
          ],
        }),
      );

      expect(v.isBlock, isTrue);
      expect(v.message, contains('read_only'));
      expect(v.message, contains('server.key'));
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

  group('FileGuard — data directory protection', () {
    late Directory tempDir;
    late String dataDir;
    late FileGuard dataGuard;

    // Unresolved on purpose: macOS temp dirs sit behind the /var symlink, and
    // the guard compares symlink-resolved paths.
    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('file_guard_data_dir_');
      dataDir = tempDir.path;
      Directory('$dataDir/credentials').createSync();
      File('$dataDir/credentials/claude.json').writeAsStringSync('{}');
      File('$dataDir/gateway_token').writeAsStringSync('t');
      File('$dataDir/dartclaw.yaml').writeAsStringSync('port: 3000');
      Directory('$dataDir/workspace').createSync();
      File('$dataDir/workspace/notes.md').writeAsStringSync('notes');
      dataGuard = FileGuard(config: FileGuardConfig.defaults().withDataDirProtection(dataDir));
    });

    tearDown(() => tempDir.deleteSync(recursive: true));

    test('blocks reading the config, gateway token and credential stores', () async {
      for (final path in ['dartclaw.yaml', 'gateway_token', 'credentials', 'credentials/claude.json']) {
        final read = await dataGuard.evaluate(_tool('file_read', {'file_path': '$dataDir/$path'}));
        expect(read.isBlock, isTrue, reason: path);
        expect(read.message, contains('no_access'), reason: path);
      }
      expect((await dataGuard.evaluate(bashGuardContext('cat $dataDir/gateway_token'))).isBlock, isTrue);
      final absent = await dataGuard.evaluate(_tool('file_write', {'file_path': '$dataDir/credentials/new.json'}));
      expect(absent.isBlock, isTrue, reason: 'a path not yet created resolves through its existing ancestors');
      expect(
        (await dataGuard.evaluate(_search('Grep', {'pattern': 'x', 'path': '$dataDir/credentials'}))).isBlock,
        isTrue,
      );
      expect((await dataGuard.evaluate(_search('Grep', {'pattern': 'x', 'path': dataDir}))).isPass, isTrue);
    });

    test('anchors on the data directory, not on file names', () async {
      expect(
        (await dataGuard.evaluate(_tool('file_read', {'file_path': '$dataDir/workspace/notes.md'}))).isPass,
        isTrue,
      );
      for (final path in ['/srv/app/gateway_token', '/srv/app/dartclaw.yaml', '/srv/app/credentials/a.json']) {
        expect((await dataGuard.evaluate(_tool('file_read', {'file_path': path}))).isPass, isTrue, reason: path);
      }
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
          {'pattern': '**/.custom.example', 'level': 'allow'},
        ],
      });
      expect(merged.rules.length, FileGuardConfig.defaults().rules.length + 2);
      expect(merged.rules.last.level, FileAccessLevel.allow);

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
      expect((await guard.evaluate(bashGuardContext('cat /home/u/.ssh/config'))).isBlock, isTrue);
      expect((await guard.evaluate(bashGuardContext('cat /home/user.ssh/config'))).isBlock, isFalse);
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

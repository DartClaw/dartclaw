import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// What `serve` does when its dedicated credential store resolves onto the
/// operator's own provider login.
///
/// The guard exists so DartClaw never chmods and writes a token into a
/// directory the operator's own `codex`/`claude` login owns. That refusal is
/// unit-covered where the guard lives; what this suite adds is the `serve`
/// boundary — the diagnostic reaching stderr and the process exiting non-zero
/// instead of the collision escaping `wire()` as an unhandled error.
///
/// The colliding "login" path is always inside this suite's own temp directory:
/// the injected environment is what makes provoking a collision possible
/// without a fixture ever resolving onto a real `~/.codex` or `~/.claude`.
late String _staticDirPath;
late String _templatesDirPath;

/// A token planted at the colliding path, so the refusal can be checked for
/// having leaked what it refused to open.
const _plantedToken = 'sk-ant-oat01-COLLISION-MUST-NOT-BE-READ';

Future<String> _resolvePackageDir(String packageRelativeAnchor) async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/$packageRelativeAnchor'));
  if (uri == null || !uri.isScheme('file')) {
    throw StateError('Could not resolve dartclaw_runtime $packageRelativeAnchor via package URI');
  }
  return p.dirname(uri.toFilePath());
}

/// A factory whose harness is never really spawned: the collision arms exit
/// long before wiring reaches it, and the control arm only needs wiring to
/// complete.
HarnessFactory _harnessFactory() {
  final factory = HarnessFactory();
  factory.register('claude', (_) => FakeAgentHarness());
  return factory;
}

/// The quoted paths a collision diagnostic names, in message order: the
/// dedicated store first, the operator login store second.
List<String> _namedPaths(String diagnostic) =>
    RegExp('"([^"]+)"').allMatches(diagnostic).map((match) => match.group(1)!).toList();

/// [path] as the guard reports it — symlinks resolved, so a macOS temp root
/// under `/var` compares equal to the `/private/var` form in the message.
///
/// Walks up to the first existing ancestor and re-appends the tail, because a
/// refused startup leaves the colliding directories uncreated.
String _resolved(String path) {
  var head = p.normalize(p.absolute(path));
  final tail = <String>[];
  while (!Directory(head).existsSync()) {
    final parent = p.dirname(head);
    if (parent == head) return p.joinAll([head, ...tail]);
    tail.insert(0, p.basename(head));
    head = parent;
  }
  return p.normalize(p.joinAll([Directory(head).resolveSymbolicLinksSync(), ...tail]));
}

/// Stands in for the process exit a real collision takes.
final class _CollisionExit implements Exception {
  const new();
}

void main() {
  late Directory tempDir;
  late Directory dataDir;
  late LogService logService;

  setUpAll(() async {
    _staticDirPath = await _resolvePackageDir('src/static/app.js');
    _templatesDirPath = await _resolvePackageDir('src/templates/audit_table.dart');
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_login_collision_');
    dataDir = Directory(p.join(tempDir.path, 'data'))..createSync(recursive: true);
    logService = LogService.fromConfig(
      format: 'human',
      level: 'INFO',
      redactor: LogRedactor(redactor: MessageRedactor()),
    );
  });

  tearDown(() async {
    await logService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  DartclawConfig configFor() => DartclawConfig(
    agent: const AgentConfig(provider: 'claude'),
    credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
    providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable)}),
    gateway: const GatewayConfig(authMode: 'none'),
    server: ServerConfig(
      dataDir: dataDir.path,
      staticDir: _staticDirPath,
      templatesDir: _templatesDirPath,
      claudeExecutable: Platform.resolvedExecutable,
    ),
  );

  /// Wires `serve` against [environment], recording what reached stderr and
  /// which exit codes were taken.
  Future<({List<String> stderr, List<int> exits})> wireExpectingRefusal(Map<String, String> environment) async {
    final config = configFor();
    final stderr = <String>[];
    final exits = <int>[];
    try {
      await DartclawRuntime.build(
        config,
        dataDir: dataDir.path,
        port: 3000,
        harnessFactory: _harnessFactory(),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        stderrLine: stderr.add,
        exitFn: (code) {
          exits.add(code);
          throw const _CollisionExit();
        },
        resolvedConfigPath: p.join(tempDir.path, 'dartclaw.yaml'),
        messageRedactor: MessageRedactor(),
        resolvedAssets: ResolvedAssets.fromSourceTree(
          templatesDir: config.server.templatesDir,
          staticDir: config.server.staticDir,
          source: AssetSource.sourceTreeDefault,
        ),
        runWorkflowSkillsBootstrap: false,
        environment: environment,
      );
      fail('assembly completed despite a login-store collision');
    } on _CollisionExit {
      // The real exitFn never returns; the marker stands in for that.
    }
    return (stderr: stderr, exits: exits);
  }

  test('a login store containing the dedicated store refuses startup, naming both paths', () async {
    // `CODEX_HOME` exported at the *parent* of DartClaw's dedicated stores. The
    // guard refuses containment as well as equality, and containment is the one
    // shape where the two colliding paths are genuinely different strings — so
    // this is the case that can prove the diagnostic fills both slots rather
    // than printing a single path twice.
    final operatorHome = p.join(dataDir.path, 'credentials');

    final outcome = await wireExpectingRefusal({'HOME': tempDir.path, 'CODEX_HOME': operatorHome});

    expect(outcome.exits, [1], reason: 'a login-store collision must fail startup closed');
    final diagnostic = outcome.stderr.join('\n');

    // Both sides named, and named as *different* paths standing in the relation
    // that made them collide: an operator cannot act on "something collided".
    // Read out of the message rather than compared to a literal, because the
    // guard reports symlink-resolved paths (`/var` is `/private/var` here).
    final quoted = _namedPaths(diagnostic);
    expect(quoted, hasLength(2), reason: 'the diagnostic did not name exactly two paths: $diagnostic');
    final dedicated = quoted.first;
    final login = quoted.last;
    expect(dedicated, isNot(login), reason: 'one path was printed into both slots');
    expect(p.isWithin(login, dedicated), isTrue, reason: 'the named paths are not the ones that collided');
    // The provider whose store collided, which is the discriminating half: the
    // remediation sentence names every relocation variable unconditionally, so
    // asserting on `CODEX_HOME` there would hold for any collision at all. A
    // login path containing the credentials directory contains the *claude*
    // store first, and that is what the guard reports.
    expect(diagnostic, contains('Dedicated claude credential store'));

    // The refusal happens before anything is created, which is the whole point:
    // a chmod or a write here would land on the operator's own login store.
    expect(
      Directory(dedicated).existsSync(),
      isFalse,
      reason: 'the refused startup created the colliding directory anyway',
    );
  });

  test('a Codex login store resolving exactly onto the dedicated store refuses too', () async {
    // The equality shape, which is what an operator pointing CODEX_HOME
    // straight at the dedicated store produces.
    final dedicatedCodexHome = p.join(dataDir.path, 'credentials', 'codex');

    final outcome = await wireExpectingRefusal({'HOME': tempDir.path, 'CODEX_HOME': dedicatedCodexHome});

    expect(outcome.exits, [1]);
    final diagnostic = outcome.stderr.join('\n');
    // Resolved, not literal: the guard reports symlink-resolved paths, and on
    // macOS the temp root resolves `/var` to `/private/var`.
    expect(_namedPaths(diagnostic), everyElement(_resolved(dedicatedCodexHome)));
    expect(diagnostic, contains('Dedicated codex credential store'));
    expect(Directory(dedicatedCodexHome).existsSync(), isFalse);
  });

  test('a Claude login store resolving onto the dedicated store refuses the same way', () async {
    final dedicatedClaudeDir = p.join(dataDir.path, 'credentials', 'claude');

    final outcome = await wireExpectingRefusal({'HOME': tempDir.path, 'CLAUDE_CONFIG_DIR': dedicatedClaudeDir});

    expect(outcome.exits, [1]);
    final diagnostic = outcome.stderr.join('\n');
    expect(_namedPaths(diagnostic), everyElement(_resolved(dedicatedClaudeDir)));
    expect(diagnostic, contains('Dedicated claude credential store'));
    expect(Directory(dedicatedClaudeDir).existsSync(), isFalse);
  });

  test('the refusal names paths without reading or echoing what is stored at them', () async {
    // A credential already sitting at the colliding path. The guard runs before
    // any read, so a diagnostic carrying this value would mean the refusal read
    // the very store it refused to open.
    final dedicatedCodexHome = Directory(p.join(dataDir.path, 'credentials', 'codex'))..createSync(recursive: true);
    File(p.join(dedicatedCodexHome.path, 'auth.json'))
        .writeAsStringSync('{"tokens":{"access_token":"$_plantedToken"}}');

    final outcome = await wireExpectingRefusal({'HOME': tempDir.path, 'CODEX_HOME': dedicatedCodexHome.path});

    expect(outcome.exits, [1]);
    final diagnostic = outcome.stderr.join('\n');
    // The diagnostic really was written: an absence check over empty stderr
    // would pass while the refusal printed nothing at all.
    expect(_namedPaths(diagnostic), everyElement(_resolved(dedicatedCodexHome.path)));
    expect(diagnostic, isNot(contains(_plantedToken)));
    // Positive control: the value really was there to leak.
    expect(File(p.join(dedicatedCodexHome.path, 'auth.json')).readAsStringSync(), contains(_plantedToken));
  });

  test('a data dir distinct from every login path opens the store without refusing', () {
    // The discriminating half: the guard refuses a collision, not a deployment.
    // Without it, every assertion above would hold for a wiring that refused
    // unconditionally.
    //
    // Asserted against the exact call `_openSubscriptionStore` makes rather
    // than through a full `wire()`: `ProjectWiring` reads `Directory.current`,
    // and this package's cwd-mutating suites delete theirs concurrently, so a
    // second full-wiring reader here would make a documented flake likelier
    // (see the package `CLAUDE.md` note on process-wide `Directory.current`).
    // The refusal path above still runs through real `wire()` — it exits before
    // projects are wired.
    final operatorHome = Directory(p.join(tempDir.path, 'operator'))..createSync(recursive: true);
    final config = configFor();

    final store = SubscriptionCredentialStore.open(
      credentialsDir: config.credentialsDir,
      environment: {'HOME': operatorHome.path},
    );

    expect(Directory(store.codexHome).existsSync(), isTrue);
    expect(Directory(store.claudeDir).existsSync(), isTrue);
    // And they were created under the data dir rather than anywhere near the
    // operator's home. Asserting the two login locations stayed absent would
    // hold under every possible input, since `open` only ever creates these
    // three paths — it would read as containment evidence and prove nothing.
    for (final created in [store.codexHome, store.claudeDir]) {
      expect(p.isWithin(config.credentialsDir, created), isTrue);
      expect(p.isWithin(operatorHome.path, created), isFalse);
    }
  });
}

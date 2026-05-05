import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('SkillProvisioner', () {
    late Directory tempRoot;
    late String dataDir;
    late String dcNativeSrc;
    late Directory fakeHome;
    late Map<String, String> fakeEnv;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('skill_provisioner_test_');
      dataDir = p.join(tempRoot.path, 'data');
      dcNativeSrc = p.join(tempRoot.path, 'dc_skills_src');
      fakeHome = Directory(p.join(tempRoot.path, 'home'))..createSync();
      fakeEnv = {'HOME': fakeHome.path};
      Directory(dataDir).createSync();
      _seedDcNativeSkills(dcNativeSrc);
    });

    tearDown(() {
      try {
        tempRoot.deleteSync(recursive: true);
      } catch (_) {}
    });

    group('ensureCacheCurrent', () {
      test('missing HOME fails before clone or install', () async {
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'abc111');
        final runner = _FakeProcessRunner(environment: const {});
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.disabled),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: const {},
          processRunner: runner.run,
        );

        await expectLater(
          provisioner.ensureCacheCurrent(),
          throwsA(
            isA<SkillProvisionException>().having(
              (e) => e.message,
              'message',
              allOf(contains('HOME/USERPROFILE'), contains('user-tier skills')),
            ),
          ),
        );
        expect(runner.calls, isEmpty);
      });

      test('disabled network with pre-staged source installs into native user-tier destination', () async {
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'abc111');
        final runner = _FakeProcessRunner(environment: fakeEnv);
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.disabled),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await provisioner.ensureCacheCurrent();

        // Installer ran exactly once for the native user-tier destination.
        final installer = runner.calls.where((c) => c.executable.endsWith('install-skills.sh')).toList();
        expect(installer, hasLength(1));
        expect(installer.single.arguments, containsAll(['--prefix', 'dartclaw-', '--display-brand', 'DartClaw']));
        expect(installer.single.arguments, contains('--claude-user'));
        expect(installer.single.arguments, isNot(contains('--skills-dir')));
        expect(installer.single.arguments, isNot(contains('--no-codex-agents')));
        expect(Directory(p.join(fakeHome.path, '.codex', 'agents')).existsSync(), isTrue);
        expect(Directory(p.join(fakeHome.path, '.claude', 'agents')).existsSync(), isTrue);

        // Marker written.
        final markerFile = File(p.join(fakeHome.path, '.agents', 'skills', skillProvisionerMarkerFile));
        expect(markerFile.existsSync(), isTrue);
        expect(markerFile.readAsStringSync(), 'abc111');

        // DC-native skills copied to both Codex and Claude trees.
        for (final name in dcNativeSkillNames) {
          expect(File(p.join(fakeHome.path, '.agents', 'skills', name, 'SKILL.md')).existsSync(), isTrue, reason: name);
          expect(File(p.join(fakeHome.path, '.claude', 'skills', name, 'SKILL.md')).existsSync(), isTrue, reason: name);
        }
      });

      test('uses configured source cache dir instead of data dir when set', () async {
        final sourceCacheDir = p.join(tempRoot.path, 'source-cache', 'andthen-src');
        _seedAndthenSrc(sourceCacheDir, sha: 'cache-sha');
        final runner = _FakeProcessRunner(environment: fakeEnv);
        final provisioner = SkillProvisioner(
          config: AndthenConfig(network: AndthenNetworkPolicy.disabled, sourceCacheDir: sourceCacheDir),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await provisioner.ensureCacheCurrent();

        expect(Directory(p.join(dataDir, 'andthen-src')).existsSync(), isFalse);
        expect(
          runner.calls.where((call) => call.executable == 'git').map((call) => call.arguments).expand((args) => args),
          contains(sourceCacheDir),
        );
        expect(
          File(p.join(fakeHome.path, '.agents', 'skills', skillProvisionerMarkerFile)).readAsStringSync(),
          'cache-sha',
        );
      });

      test('disabled network checks out the configured ref from the cached source', () async {
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'develop-sha');
        final runner = _FakeProcessRunner(environment: fakeEnv)..remoteTrackingRefs.add('origin/develop');
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(ref: 'develop', network: AndthenNetworkPolicy.disabled),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await provisioner.ensureCacheCurrent();

        final checkoutCalls = runner.calls.where((c) => c.executable == 'git' && c.arguments.contains('checkout'));
        final resetCalls = runner.calls.where((c) => c.executable == 'git' && c.arguments.contains('reset')).toList();
        expect(checkoutCalls, isNotEmpty, reason: 'cached source must still enforce andthen.ref');
        expect(resetCalls, hasLength(1));
        expect(resetCalls.single.arguments.last, 'origin/develop');
      });

      test('disabled network fails when the cached source cannot resolve the configured ref', () async {
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'old-sha');
        final runner = _FakeProcessRunner(environment: fakeEnv)
          ..gitCheckoutExitCode = 1
          ..gitCheckoutStderr = 'pathspec ref-not-cached did not match';
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(ref: 'ref-not-cached', network: AndthenNetworkPolicy.disabled),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await expectLater(
          provisioner.ensureCacheCurrent(),
          throwsA(
            isA<SkillProvisionException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('andthen.network=disabled'),
                contains('andthen.ref="ref-not-cached"'),
                contains('could not be resolved locally'),
              ),
            ),
          ),
        );
      });

      test('disabled network without pre-staged source throws clear error', () async {
        final runner = _FakeProcessRunner(environment: fakeEnv);
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.disabled),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await expectLater(
          provisioner.ensureCacheCurrent(),
          throwsA(
            isA<SkillProvisionException>().having(
              (e) => e.message,
              'message',
              allOf(contains('andthen.network=disabled'), contains('no cached AndThen source')),
            ),
          ),
        );
      });

      test('matched marker + complete tree is a no-op on subsequent run', () async {
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'noop-sha');
        final runner = _FakeProcessRunner(environment: fakeEnv);
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.disabled),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await provisioner.ensureCacheCurrent();
        runner.calls.clear();
        await provisioner.ensureCacheCurrent();

        expect(
          runner.calls.where((c) => c.executable.endsWith('install-skills.sh')),
          isEmpty,
          reason: 'second run should skip install',
        );
      });

      test('source SHA bump re-runs installer and updates marker', () async {
        final srcDir = p.join(dataDir, 'andthen-src');
        _seedAndthenSrc(srcDir, sha: 'sha-old');
        final runner = _FakeProcessRunner(environment: fakeEnv);
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.disabled),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await provisioner.ensureCacheCurrent();
        // Bump SHA in the seeded source.
        runner.shaOverride = 'sha-new';
        runner.calls.clear();
        await provisioner.ensureCacheCurrent();

        expect(runner.calls.where((c) => c.executable.endsWith('install-skills.sh')), hasLength(1));
        expect(
          File(p.join(fakeHome.path, '.agents', 'skills', skillProvisionerMarkerFile)).readAsStringSync(),
          'sha-new',
        );
      });

      test('marker-present partial install repairs missing AndThen skill', () async {
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'sha-partial');
        final runner = _FakeProcessRunner(environment: fakeEnv);
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.disabled),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );
        await provisioner.ensureCacheCurrent();

        // Simulate operator deleting the dartclaw-prd skill while marker stays.
        Directory(p.join(fakeHome.path, '.agents', 'skills', 'dartclaw-prd')).deleteSync(recursive: true);
        runner.calls.clear();

        await provisioner.ensureCacheCurrent();
        expect(runner.calls.where((c) => c.executable.endsWith('install-skills.sh')), hasLength(1));
        expect(File(p.join(fakeHome.path, '.agents', 'skills', 'dartclaw-prd', 'SKILL.md')).existsSync(), isTrue);
      });

      test('marker-present partial install repairs missing DC-native skill', () async {
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'sha-dc');
        final runner = _FakeProcessRunner(environment: fakeEnv);
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.disabled),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );
        await provisioner.ensureCacheCurrent();

        // Delete a DC-native skill copy.
        Directory(p.join(fakeHome.path, '.claude', 'skills', 'dartclaw-merge-resolve')).deleteSync(recursive: true);
        runner.calls.clear();

        await provisioner.ensureCacheCurrent();
        expect(runner.calls.where((c) => c.executable.endsWith('install-skills.sh')), hasLength(1));
        expect(
          File(p.join(fakeHome.path, '.claude', 'skills', 'dartclaw-merge-resolve', 'SKILL.md')).existsSync(),
          isTrue,
        );
      });

      test('marker-present partial install repairs missing claudeAgentsDir', () async {
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'sha-agents');
        final runner = _FakeProcessRunner(environment: fakeEnv);
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.disabled),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );
        await provisioner.ensureCacheCurrent();

        Directory(p.join(fakeHome.path, '.claude', 'agents')).deleteSync(recursive: true);
        runner.calls.clear();

        await provisioner.ensureCacheCurrent();
        expect(runner.calls.where((c) => c.executable.endsWith('install-skills.sh')), hasLength(1));
      });

      test('marker-present partial install repairs missing codexAgentsDir', () async {
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'sha-codex-agents');
        final runner = _FakeProcessRunner(environment: fakeEnv);
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.disabled),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );
        await provisioner.ensureCacheCurrent();

        Directory(p.join(fakeHome.path, '.codex', 'agents')).deleteSync(recursive: true);
        runner.calls.clear();

        await provisioner.ensureCacheCurrent();
        expect(runner.calls.where((c) => c.executable.endsWith('install-skills.sh')), hasLength(1));
      });

      test('marker-present partial install repairs missing native agent files', () async {
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'sha-agent-files');
        final runner = _FakeProcessRunner(environment: fakeEnv);
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.disabled),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );
        await provisioner.ensureCacheCurrent();

        File(p.join(fakeHome.path, '.codex', 'agents', 'dartclaw-documentation-lookup.toml')).deleteSync();
        File(p.join(fakeHome.path, '.claude', 'agents', 'dartclaw-documentation-lookup.md')).deleteSync();
        runner.calls.clear();

        await provisioner.ensureCacheCurrent();
        expect(runner.calls.where((c) => c.executable.endsWith('install-skills.sh')), hasLength(1));
        expect(
          File(p.join(fakeHome.path, '.codex', 'agents', 'dartclaw-documentation-lookup.toml')).existsSync(),
          isTrue,
        );
        expect(
          File(p.join(fakeHome.path, '.claude', 'agents', 'dartclaw-documentation-lookup.md')).existsSync(),
          isTrue,
        );
      });

      test('missing marker triggers install even with complete trees', () async {
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'sha-marker');
        final runner = _FakeProcessRunner(environment: fakeEnv);
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.disabled),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );
        await provisioner.ensureCacheCurrent();

        File(p.join(fakeHome.path, '.agents', 'skills', skillProvisionerMarkerFile)).deleteSync();
        runner.calls.clear();

        await provisioner.ensureCacheCurrent();
        expect(runner.calls.where((c) => c.executable.endsWith('install-skills.sh')), hasLength(1));
      });

      test('installer non-zero exit surfaces stderr verbatim', () async {
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'sha-fail');
        final runner = _FakeProcessRunner(environment: fakeEnv)
          ..installerExitCode = 17
          ..installerStderr = 'BANG: skill X invalid';
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.disabled),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await expectLater(
          provisioner.ensureCacheCurrent(),
          throwsA(
            isA<SkillProvisionException>().having(
              (e) => e.message,
              'message',
              allOf(contains('exit 17'), contains('BANG: skill X invalid')),
            ),
          ),
        );
      });

      test('network: required failure throws (no fallback)', () async {
        // No pre-staged src; require network; runner fails clone.
        final runner = _FakeProcessRunner(environment: fakeEnv)
          ..gitCloneExitCode = 128
          ..gitCloneStderr = 'no route';
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.required),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await expectLater(
          provisioner.ensureCacheCurrent(),
          throwsA(isA<SkillProvisionException>().having((e) => e.message, 'message', contains('git clone'))),
        );
      });

      test('rejects non-https git URLs before invoking git', () async {
        final runner = _FakeProcessRunner(environment: fakeEnv);
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(
            gitUrl: 'ssh://github.com/IT-HUSET/andthen',
            network: AndthenNetworkPolicy.required,
          ),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await expectLater(
          provisioner.ensureCacheCurrent(),
          throwsA(isA<SkillProvisionConfigException>().having((e) => e.message, 'message', contains('https:// URL'))),
        );
        expect(runner.calls, isEmpty);
      });

      test('passes clone URL after option terminator', () async {
        final runner = _FakeProcessRunner(environment: fakeEnv);
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.required),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await provisioner.ensureCacheCurrent();

        final cloneCall = runner.calls.firstWhere(
          (call) => call.executable == 'git' && call.arguments.first == 'clone',
        );
        expect(cloneCall.arguments.take(3).toList(), ['clone', '--', const AndthenConfig().gitUrl]);
      });

      test('network: auto falls back to cache when network fails and cache exists', () async {
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'cached-sha');
        final runner = _FakeProcessRunner(environment: fakeEnv)
          ..gitFetchExitCode = 1
          ..gitFetchStderr = 'transient';
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.auto),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await provisioner.ensureCacheCurrent();
        expect(
          File(p.join(fakeHome.path, '.agents', 'skills', skillProvisionerMarkerFile)).readAsStringSync(),
          'cached-sha',
        );
        expect(
          runner.calls.any((c) => c.executable == 'git' && c.arguments.contains('checkout')),
          isTrue,
          reason: 'auto fallback must enforce andthen.ref against the cached source',
        );
        expect(
          runner.calls.any((c) => c.executable == 'git' && c.arguments.contains('reset')),
          isTrue,
          reason: 'auto fallback must reset the cache to the configured ref when it can resolve locally',
        );
      });

      test('network: auto fails when no cache and network fails', () async {
        final runner = _FakeProcessRunner(environment: fakeEnv)
          ..gitCloneExitCode = 128
          ..gitCloneStderr = 'unreachable';
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.auto),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await expectLater(
          provisioner.ensureCacheCurrent(),
          throwsA(
            isA<SkillProvisionException>().having(
              (e) => e.message,
              'message',
              allOf(contains('andthen.network=auto'), contains('no cached source')),
            ),
          ),
        );
      });

      test('branch ref resets to origin/<branch> so subsequent runs fast-forward', () async {
        // Pre-stage the cache so `_doNetworkClone` takes the fetch+checkout
        // branch and `_checkout` runs against an existing repo.
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'sha-branch');
        final runner = _FakeProcessRunner(environment: fakeEnv)
          ..remoteTrackingRefs.addAll({'origin/main', 'origin/develop'});
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(ref: 'develop', network: AndthenNetworkPolicy.required),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await provisioner.ensureCacheCurrent();

        final resetCalls = runner.calls.where((c) => c.executable == 'git' && c.arguments.contains('reset')).toList();
        expect(resetCalls, hasLength(1));
        expect(
          resetCalls.single.arguments.last,
          'origin/develop',
          reason: 'branch refs must reset to origin/<ref> to actually fast-forward',
        );
      });

      test('tag ref resets to the ref itself (no origin/ prefix)', () async {
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'sha-tag');
        // remoteTrackingRefs intentionally omits `origin/v0.16.0` — the probe
        // should miss and fall back to resetting to the ref directly.
        final runner = _FakeProcessRunner(environment: fakeEnv);
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(ref: 'v0.16.0', network: AndthenNetworkPolicy.required),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await provisioner.ensureCacheCurrent();

        final resetCalls = runner.calls.where((c) => c.executable == 'git' && c.arguments.contains('reset')).toList();
        expect(resetCalls, hasLength(1));
        expect(resetCalls.single.arguments.last, 'v0.16.0');
      });

      test('claudeAgentsDir is materialized after install (defensive)', () async {
        _seedAndthenSrc(p.join(dataDir, 'andthen-src'), sha: 'sha-agents-mkdir');
        // Override the default fake installer to NOT create claudeAgentsDir
        // — proves the provisioner still ends up with the dir present.
        final runner = _StubInstallerNoAgentsDirRunner();
        final provisioner = SkillProvisioner(
          config: const AndthenConfig(network: AndthenNetworkPolicy.disabled),
          dataDir: dataDir,
          dcNativeSkillsSourceDir: dcNativeSrc,
          environment: fakeEnv,
          processRunner: runner.run,
        );

        await provisioner.ensureCacheCurrent();

        expect(Directory(p.join(fakeHome.path, '.claude', 'agents')).existsSync(), isTrue);
      });
    });
  });
}

void _seedDcNativeSkills(String dir) {
  for (final name in dcNativeSkillNames) {
    final skillDir = Directory(p.join(dir, name))..createSync(recursive: true);
    File(p.join(skillDir.path, 'SKILL.md')).writeAsStringSync('---\nname: $name\n---\nbody\n');
  }
}

/// Seed a fake `andthen-src` such that the FakeProcessRunner can pretend
/// `git rev-parse HEAD` returned [sha] and the installer can be located.
void _seedAndthenSrc(String srcDir, {required String sha}) {
  Directory(srcDir).createSync(recursive: true);
  Directory(p.join(srcDir, '.git')).createSync(recursive: true);
  // Pseudo install-skills.sh — the FakeProcessRunner intercepts execution; this
  // file just needs to exist so the path check passes.
  final scriptDir = Directory(p.join(srcDir, 'scripts'))..createSync(recursive: true);
  File(p.join(scriptDir.path, 'install-skills.sh')).writeAsStringSync('#!/bin/sh\nexit 0\n');
  final pluginAgentsDir = Directory(p.join(srcDir, 'plugin', 'agents'))..createSync(recursive: true);
  for (final name in _andThenAgentNames) {
    File(p.join(pluginAgentsDir.path, '$name.md')).writeAsStringSync('# $name\n');
  }
  // Stash the seeded SHA where the FakeProcessRunner can find it via stat.
  File(p.join(srcDir, '.git', 'HEAD_SHA')).writeAsStringSync(sha);
}

const _andThenAgentNames = ['documentation-lookup'];

class _FakeProcessRunner {
  final List<({String executable, List<String> arguments, String? workingDirectory})> calls = [];

  /// Environment used to resolve user-tier defaults when the installer is
  /// invoked with `--claude-user`. Tests mirror the same `HOME` they pass to
  /// [SkillProvisioner.environment] so the fake never touches the real `$HOME`.
  final Map<String, String> environment;

  String? shaOverride;
  int installerExitCode = 0;
  String installerStderr = '';
  int gitCloneExitCode = 0;
  String gitCloneStderr = '';
  int gitFetchExitCode = 0;
  String gitFetchStderr = '';
  int gitCheckoutExitCode = 0;
  String gitCheckoutStderr = '';
  int gitResetExitCode = 0;
  String gitResetStderr = '';

  /// Refs (in `origin/<name>` form) the fake should treat as remote-tracking.
  /// Used by the `rev-parse --verify --quiet origin/<ref>` probe in
  /// `_checkout` to decide whether to reset to `origin/<ref>` (branch) or
  /// `<ref>` directly (tag/SHA).
  final Set<String> remoteTrackingRefs = {'origin/main'};

  _FakeProcessRunner({Map<String, String>? environment}) : environment = environment ?? const {};

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add((executable: executable, arguments: arguments, workingDirectory: workingDirectory));

    if (executable.endsWith('install-skills.sh')) {
      // Simulate the script: create the per-skill directories so the
      // completeness check can pass on subsequent runs.
      final isUserTier = arguments.contains('--claude-user');
      String? skillsDir;
      String? codexAgentsDir;
      String? claudeSkillsDir;
      String? claudeAgentsDir;
      for (var i = 0; i < arguments.length - 1; i++) {
        switch (arguments[i]) {
          case '--skills-dir':
            skillsDir = arguments[i + 1];
          case '--codex-agents-dir':
            codexAgentsDir = arguments[i + 1];
          case '--claude-skills-dir':
            claudeSkillsDir = arguments[i + 1];
          case '--claude-agents-dir':
            claudeAgentsDir = arguments[i + 1];
        }
      }
      if (isUserTier) {
        // Prefer the per-call environment forwarded by SkillProvisioner, then
        // fall back to the runner's constructor environment. Either way, the
        // fake never reads `Platform.environment['HOME']`, so it cannot leak
        // fake skills into the developer's real home.
        final home = environment?['HOME'] ?? this.environment['HOME'] ?? '';
        if (home.isEmpty) {
          throw StateError(
            'FakeProcessRunner refused to expand user-tier paths without a fake HOME — '
            'pass `environment: {"HOME": fakeHome.path}` to both SkillProvisioner and '
            '_FakeProcessRunner.',
          );
        }
        skillsDir ??= p.join(home, '.agents', 'skills');
        codexAgentsDir ??= p.join(home, '.codex', 'agents');
        claudeSkillsDir ??= p.join(home, '.claude', 'skills');
        claudeAgentsDir ??= p.join(home, '.claude', 'agents');
      }
      if (installerExitCode == 0 &&
          skillsDir != null &&
          codexAgentsDir != null &&
          claudeSkillsDir != null &&
          claudeAgentsDir != null) {
        for (final dir in [skillsDir, codexAgentsDir, claudeSkillsDir, claudeAgentsDir]) {
          Directory(dir).createSync(recursive: true);
        }
        for (final name in const ['dartclaw-prd', 'dartclaw-spec', 'dartclaw-exec-spec']) {
          File(p.join(skillsDir, name, 'SKILL.md'))
            ..createSync(recursive: true)
            ..writeAsStringSync('# $name\n');
          File(p.join(claudeSkillsDir, name, 'SKILL.md'))
            ..createSync(recursive: true)
            ..writeAsStringSync('# $name\n');
        }
        for (final name in _andThenAgentNames) {
          File(p.join(codexAgentsDir, 'dartclaw-$name.toml'))
            ..createSync(recursive: true)
            ..writeAsStringSync('name = "dartclaw-$name"\n');
          File(p.join(claudeAgentsDir, 'dartclaw-$name.md'))
            ..createSync(recursive: true)
            ..writeAsStringSync('# dartclaw-$name\n');
        }
      }
      return ProcessResult(0, installerExitCode, '', installerStderr);
    }

    if (executable == 'git') {
      if (arguments.first == 'clone') {
        if (gitCloneExitCode != 0) return ProcessResult(0, gitCloneExitCode, '', gitCloneStderr);
        final dest = arguments.last;
        Directory(p.join(dest, '.git')).createSync(recursive: true);
        Directory(p.join(dest, 'scripts')).createSync(recursive: true);
        File(p.join(dest, 'scripts', 'install-skills.sh')).writeAsStringSync('#!/bin/sh\nexit 0\n');
        final pluginAgentsDir = Directory(p.join(dest, 'plugin', 'agents'))..createSync(recursive: true);
        for (final name in _andThenAgentNames) {
          File(p.join(pluginAgentsDir.path, '$name.md')).writeAsStringSync('# $name\n');
        }
        File(p.join(dest, '.git', 'HEAD_SHA')).writeAsStringSync(shaOverride ?? 'abcdef1');
        return ProcessResult(0, 0, '', '');
      }
      if (arguments.contains('fetch')) {
        return ProcessResult(0, gitFetchExitCode, '', gitFetchStderr);
      }
      if (arguments.contains('checkout')) {
        return ProcessResult(0, gitCheckoutExitCode, '', gitCheckoutStderr);
      }
      if (arguments.contains('reset')) {
        return ProcessResult(0, gitResetExitCode, '', gitResetStderr);
      }
      if (arguments.contains('rev-parse')) {
        // `rev-parse --verify --quiet origin/<ref>` probes whether a ref is a
        // remote-tracking branch. Only matches refs in `remoteTrackingRefs`.
        if (arguments.contains('--verify')) {
          final probedRef = arguments.last;
          return remoteTrackingRefs.contains(probedRef)
              ? ProcessResult(0, 0, '$probedRef\n', '')
              : ProcessResult(0, 1, '', '');
        }
        // Resolve src dir from the `-C <src>` argument.
        final cIdx = arguments.indexOf('-C');
        if (cIdx >= 0 && cIdx + 1 < arguments.length) {
          if (shaOverride != null) {
            return ProcessResult(0, 0, '$shaOverride\n', '');
          }
          final shaFile = File(p.join(arguments[cIdx + 1], '.git', 'HEAD_SHA'));
          if (shaFile.existsSync()) {
            return ProcessResult(0, 0, '${shaFile.readAsStringSync().trim()}\n', '');
          }
          return ProcessResult(0, 0, 'sha-default\n', '');
        }
        return ProcessResult(0, 0, 'sha-default\n', '');
      }
    }

    return ProcessResult(0, 0, '', '');
  }
}

/// Variant of [_FakeProcessRunner] whose stub installer creates the AndThen
/// and Claude skill trees but intentionally skips the Claude agents dir,
/// modeling a future AndThen release that drops `plugin/agents/`. Used to
/// prove the provisioner's defensive `mkdir` keeps the completeness gate
/// stable in that case.
class _StubInstallerNoAgentsDirRunner {
  final List<({String executable, List<String> arguments, String? workingDirectory})> calls = [];

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add((executable: executable, arguments: arguments, workingDirectory: workingDirectory));

    if (executable.endsWith('install-skills.sh')) {
      String? skillsDir;
      String? claudeSkillsDir;
      for (var i = 0; i < arguments.length - 1; i++) {
        switch (arguments[i]) {
          case '--skills-dir':
            skillsDir = arguments[i + 1];
          case '--claude-skills-dir':
            claudeSkillsDir = arguments[i + 1];
        }
      }
      if (skillsDir != null && claudeSkillsDir != null) {
        for (final name in const ['dartclaw-prd']) {
          File(p.join(skillsDir, name, 'SKILL.md'))
            ..createSync(recursive: true)
            ..writeAsStringSync('# $name\n');
          File(p.join(claudeSkillsDir, name, 'SKILL.md'))
            ..createSync(recursive: true)
            ..writeAsStringSync('# $name\n');
        }
      }
      // Deliberately no claude-agents-dir mkdir.
      return ProcessResult(0, 0, '', '');
    }
    if (executable == 'git') {
      if (arguments.contains('rev-parse')) {
        return ProcessResult(0, 0, 'sha-agents-mkdir\n', '');
      }
      return ProcessResult(0, 0, '', '');
    }
    return ProcessResult(0, 0, '', '');
  }
}

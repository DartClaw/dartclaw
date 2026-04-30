import 'dart:async';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart'
    show AndthenConfig, AndthenInstallScope, AndthenNetworkPolicy, expandHome;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Function shape for invoking a child process. Injectable for tests.
typedef ProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

/// Filesystem-recursive directory copy. Injectable for tests.
typedef DirectoryCopier = Future<void> Function(Directory source, Directory destination);

/// Default DC-native skill names that get copied alongside the AndThen install.
///
/// Matches the public repo's `packages/dartclaw_workflow/skills/` inventory.
/// Listed explicitly so cleanup can never wildcard-delete a skill that should
/// be retained when the provisioned AndThen tree is refreshed.
const dcNativeSkillNames = <String>[
  'dartclaw-discover-project',
  'dartclaw-validate-workflow',
  'dartclaw-merge-resolve',
];

/// Marker filename written under each install destination's `skillsDir` to
/// record which AndThen commit SHA the destination was last installed from.
const skillProvisionerMarkerFile = '.dartclaw-andthen-sha';

/// Thrown for config/CWD validation failures.
///
/// Caught at the `dartclaw serve` startup boundary and surfaced to stderr.
class SkillProvisionConfigException implements Exception {
  final String message;
  const SkillProvisionConfigException(this.message);

  @override
  String toString() => 'SkillProvisionConfigException: $message';
}

/// Thrown when clone, install, or copy fails irrecoverably.
class SkillProvisionException implements Exception {
  final String message;
  const SkillProvisionException(this.message);

  @override
  String toString() => 'SkillProvisionException: $message';
}

/// Resolved install destination — one per installScope leg.
class _InstallDestination {
  /// Codex-tier skills (e.g. `<dataDir>/.agents/skills` or `~/.agents/skills`).
  final String skillsDir;

  /// Claude Code skills tier (e.g. `<dataDir>/.claude/skills` or `~/.claude/skills`).
  final String claudeSkillsDir;

  /// Claude Code agents tier (e.g. `<dataDir>/.claude/agents` or `~/.claude/agents`).
  ///
  /// DartClaw materializes this directory after installer success so
  /// destination-completeness checks stay stable even when upstream ships no
  /// Claude agents.
  final String claudeAgentsDir;

  /// Whether this destination uses `--claude-user` (user-tier defaults inside
  /// the installer) instead of explicit per-dir overrides.
  final bool useClaudeUser;

  /// Human-friendly label used in logs/errors.
  final String label;

  const _InstallDestination({
    required this.skillsDir,
    required this.claudeSkillsDir,
    required this.claudeAgentsDir,
    required this.useClaudeUser,
    required this.label,
  });

  String get markerPath => p.join(skillsDir, skillProvisionerMarkerFile);
}

/// Runtime provisioner for AndThen-derived workflow skills.
///
/// At `dartclaw serve` startup, [ensureCacheCurrent] clones AndThen into
/// `<dataDir>/andthen-src/`, runs AndThen's own `scripts/install-skills.sh
/// --prefix dartclaw- --display-brand DartClaw` into the configured destination(s), and copies the
/// DC-native skills (`dartclaw-discover-project`, `dartclaw-validate-workflow`,
/// `dartclaw-merge-resolve`) into the same skill trees.
///
/// Re-install is gated by the AndThen commit SHA written to a per-destination
/// marker file plus a destination-completeness check; partial installs are
/// repaired regardless of marker matching.
class SkillProvisioner {
  static final _log = Logger('SkillProvisioner');

  final AndthenConfig config;
  final String dataDir;
  final String dcNativeSkillsSourceDir;
  final Map<String, String> environment;
  final ProcessRunner _runProcess;
  final DirectoryCopier _copyDirectory;

  SkillProvisioner({
    required this.config,
    required this.dataDir,
    required this.dcNativeSkillsSourceDir,
    Map<String, String>? environment,
    ProcessRunner? processRunner,
    DirectoryCopier? directoryCopier,
  }) : environment = environment ?? Platform.environment,
       _runProcess = processRunner ?? _defaultProcessRunner,
       _copyDirectory = directoryCopier ?? _defaultDirectoryCopier;

  /// Pure validation: throws if [installScope] is `dataDir` and any spawn-target
  /// CWD lives outside `<dataDir>`.
  ///
  /// Spawn-target CWDs come from registered project `localPath` values plus the
  /// `Directory.current.path` captured at `dartclaw serve` startup. Validation
  /// runs before any network or filesystem work so misconfiguration surfaces as
  /// a fast non-zero `dartclaw serve` exit.
  ///
  /// Throws [SkillProvisionConfigException] at this direct call site. Note:
  /// `ServiceWiring.wire()` rewraps that as [SkillProvisionException] at the
  /// startup boundary so all skill-provisioning failures surface a single
  /// exception type to the operator.
  void validateSpawnTargets(List<String> spawnCwds) {
    if (config.installScope != AndthenInstallScope.dataDir) return;

    final dataDirAbs = p.normalize(p.absolute(dataDir));
    for (final raw in spawnCwds) {
      if (raw.isEmpty) continue;
      final candidate = p.normalize(p.absolute(raw));
      if (candidate == dataDirAbs) continue;
      if (p.isWithin(dataDirAbs, candidate)) continue;
      throw SkillProvisionConfigException(
        'andthen.install_scope=data_dir cannot serve spawn target "$raw" because '
        'it is outside <data_dir>="$dataDirAbs". '
        'Choose one of: install_scope: user (use ~/.claude/skills + ~/.agents/skills) '
        'or install_scope: both (install into both <data_dir> and user-tier).',
      );
    }
  }

  /// Clone-or-pull AndThen, then run the installer for each resolved
  /// destination whose marker SHA differs from the source HEAD or whose tree
  /// is incomplete. Idempotent within a single process.
  Future<void> ensureCacheCurrent() async {
    final destinations = _resolveDestinations();
    final srcDir = p.join(dataDir, 'andthen-src');

    await _cloneOrPull(srcDir);

    final sha = await _currentSha(srcDir);
    if (sha.isEmpty) {
      throw const SkillProvisionException('Could not resolve AndThen source HEAD SHA after clone/pull.');
    }

    for (final dest in destinations) {
      if (await _destinationIsComplete(dest, sha)) {
        _log.fine('Skill destination ${dest.label} is complete at $sha — skipping install.');
        continue;
      }
      _log.info('Installing AndThen skills into ${dest.label} at $sha');
      await _runInstallSkills(srcDir, dest);
      await _copyDcNativeSkills(dest);
      await _writeMarker(dest, sha);
    }
  }

  void _validateGitUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      throw const SkillProvisionConfigException('andthen.git_url must not be empty.');
    }
    if (trimmed.startsWith('-')) {
      throw SkillProvisionConfigException('andthen.git_url must be a URL, not a git option: "$rawUrl".');
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.scheme.toLowerCase() != 'https' || uri.host.isEmpty) {
      throw SkillProvisionConfigException(
        'andthen.git_url must be an https:// URL with a hostname. '
        'Rejecting "$rawUrl".',
      );
    }
    if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) {
      throw SkillProvisionConfigException(
        'andthen.git_url must not contain userinfo, query parameters, or fragments. '
        'Rejecting "$rawUrl".',
      );
    }

    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host.endsWith('.localhost')) {
      throw SkillProvisionConfigException('andthen.git_url must not target localhost: "$rawUrl".');
    }
    // Reject IP-literal hosts (IPv4 / IPv6). The `localhost` check above is
    // trivially defeated by DNS, so we additionally refuse anything that
    // parses as a raw IP address — `git_url` is expected to be a hostname.
    if (InternetAddress.tryParse(host) != null) {
      throw SkillProvisionConfigException(
        'andthen.git_url must use a hostname, not an IP literal: "$rawUrl".',
      );
    }
  }

  // ── Internals (visible to tests via @visibleForTesting wrappers below) ────

  List<_InstallDestination> _resolveDestinations() {
    final dataDirAbs = p.normalize(p.absolute(dataDir));
    final dataDest = _InstallDestination(
      label: 'data_dir',
      skillsDir: p.join(dataDirAbs, '.agents', 'skills'),
      claudeSkillsDir: p.join(dataDirAbs, '.claude', 'skills'),
      claudeAgentsDir: p.join(dataDirAbs, '.claude', 'agents'),
      useClaudeUser: false,
    );
    final userDest = _InstallDestination(
      label: 'user',
      skillsDir: expandHome('~/.agents/skills', env: environment),
      claudeSkillsDir: expandHome('~/.claude/skills', env: environment),
      claudeAgentsDir: expandHome('~/.claude/agents', env: environment),
      useClaudeUser: true,
    );
    return switch (config.installScope) {
      AndthenInstallScope.dataDir => [dataDest],
      AndthenInstallScope.user => [userDest],
      AndthenInstallScope.both => [dataDest, userDest],
    };
  }

  Future<void> _cloneOrPull(String srcDir) async {
    final dir = Directory(srcDir);
    final exists = dir.existsSync() && Directory(p.join(srcDir, '.git')).existsSync();

    switch (config.network) {
      case AndthenNetworkPolicy.disabled:
        if (!exists) {
          throw SkillProvisionException(
            'andthen.network=disabled but no cached AndThen source at $srcDir. '
            'Pre-stage the clone or set andthen.network to "auto" or "required".',
          );
        }
        _log.info('andthen.network=disabled — using cached source at $srcDir');
        await _checkoutCached(srcDir, policy: 'andthen.network=disabled');
        return;
      case AndthenNetworkPolicy.required:
        await _doNetworkClone(srcDir, exists, allowOfflineFallback: false);
        return;
      case AndthenNetworkPolicy.auto:
        try {
          await _doNetworkClone(srcDir, exists, allowOfflineFallback: true);
        } on SkillProvisionException catch (e) {
          if (!exists) {
            throw SkillProvisionException(
              'andthen.network=auto: network unreachable and no cached source. ${e.message}',
            );
          }
          _log.warning('Network clone/pull failed, falling back to cached source: ${e.message}');
          await _checkoutCached(srcDir, policy: 'andthen.network=auto fallback');
        }
        return;
    }
  }

  Future<void> _doNetworkClone(String srcDir, bool exists, {required bool allowOfflineFallback}) async {
    if (!exists) {
      _validateGitUrl(config.gitUrl);
      Directory(p.dirname(srcDir)).createSync(recursive: true);
      final result = await _runProcess('git', ['clone', '--', config.gitUrl, srcDir]);
      if (result.exitCode != 0) {
        throw SkillProvisionException(
          'git clone of ${config.gitUrl} failed (exit ${result.exitCode}): ${result.stderr}',
        );
      }
      await _checkout(srcDir);
      return;
    }

    final fetch = await _runProcess('git', ['-C', srcDir, 'fetch', '--prune', 'origin']);
    if (fetch.exitCode != 0) {
      throw SkillProvisionException('git fetch failed (exit ${fetch.exitCode}): ${fetch.stderr}');
    }
    await _checkout(srcDir);
  }

  Future<void> _checkoutCached(String srcDir, {required String policy}) async {
    try {
      await _checkout(srcDir);
    } on SkillProvisionException catch (e) {
      throw SkillProvisionException(
        '$policy selected cached AndThen source at $srcDir, but configured '
        'andthen.ref="${config.ref}" could not be resolved locally. '
        'Refresh the cache with network access or choose a ref already present in the cache. '
        '${e.message}',
      );
    }
  }

  Future<void> _checkout(String srcDir) async {
    final ref = config.ref;
    final isLatest = ref == 'latest';

    // For `latest` and any other ref that resolves to a remote-tracking branch,
    // reset to `origin/<branch>` so subsequent runs actually fast-forward after
    // `git fetch`. Resetting to the local branch name would be a no-op because
    // `git fetch` updates `refs/remotes/origin/*` only, leaving local branches
    // pinned. Tags and bare SHAs don't have an `origin/<ref>` form — fall back
    // to the ref itself for them (`git checkout` produces a detached HEAD).
    final String target;
    if (isLatest) {
      target = 'origin/main';
    } else {
      final probe = await _runProcess('git', ['-C', srcDir, 'rev-parse', '--verify', '--quiet', 'origin/$ref']);
      target = probe.exitCode == 0 ? 'origin/$ref' : ref;
    }

    final checkout = await _runProcess('git', ['-C', srcDir, 'checkout', isLatest ? 'main' : ref]);
    if (checkout.exitCode != 0) {
      throw SkillProvisionException('git checkout $ref failed (exit ${checkout.exitCode}): ${checkout.stderr}');
    }

    final reset = await _runProcess('git', ['-C', srcDir, 'reset', '--hard', target]);
    if (reset.exitCode != 0) {
      throw SkillProvisionException('git reset --hard $target failed (exit ${reset.exitCode}): ${reset.stderr}');
    }
  }

  Future<String> _currentSha(String srcDir) async {
    final result = await _runProcess('git', ['-C', srcDir, 'rev-parse', 'HEAD']);
    if (result.exitCode != 0) {
      throw SkillProvisionException('git rev-parse HEAD failed (exit ${result.exitCode}): ${result.stderr}');
    }
    return (result.stdout as String).trim();
  }

  Future<bool> _destinationIsComplete(_InstallDestination dest, String sha) async {
    final markerFile = File(dest.markerPath);
    if (!markerFile.existsSync()) return false;

    final markerContents = (await markerFile.readAsString()).trim();
    if (markerContents != sha) return false;

    // `dartclaw-prd` is the canary skill. If upstream ever
    // renames or drops it, this check needs to follow.
    if (!File(p.join(dest.skillsDir, 'dartclaw-prd', 'SKILL.md')).existsSync()) return false;
    if (!File(p.join(dest.claudeSkillsDir, 'dartclaw-prd', 'SKILL.md')).existsSync()) return false;
    if (!Directory(dest.claudeAgentsDir).existsSync()) return false;

    for (final name in dcNativeSkillNames) {
      if (!File(p.join(dest.skillsDir, name, 'SKILL.md')).existsSync()) return false;
      if (!File(p.join(dest.claudeSkillsDir, name, 'SKILL.md')).existsSync()) return false;
    }
    return true;
  }

  Future<void> _runInstallSkills(String srcDir, _InstallDestination dest) async {
    final script = p.join(srcDir, 'scripts', 'install-skills.sh');
    if (!File(script).existsSync()) {
      throw SkillProvisionException('install-skills.sh missing at $script — check andthen.ref/git_url.');
    }

    final args = <String>['--prefix', 'dartclaw-', '--display-brand', 'DartClaw'];
    if (dest.useClaudeUser) {
      args.add('--claude-user');
    } else {
      args
        ..addAll(['--skills-dir', dest.skillsDir])
        ..addAll(['--claude-skills-dir', dest.claudeSkillsDir])
        ..addAll(['--claude-agents-dir', dest.claudeAgentsDir]);
    }

    // Forward the provisioner's environment to the spawned installer so
    // user-tier paths (`~/.agents/skills`, `~/.claude/...`) expand from the
    // same `HOME` the provisioner used to resolve destinations. In production
    // `this.environment` is `Platform.environment`, so the script behaves
    // exactly as if invoked directly; in tests, an injected `HOME` keeps the
    // installer from touching the developer's real user-tier paths.
    final processEnv = identical(environment, Platform.environment) ? null : environment;
    final result = await _runProcess(script, args, workingDirectory: srcDir, environment: processEnv);
    if (result.exitCode != 0) {
      throw SkillProvisionException(
        'install-skills.sh failed for ${dest.label} (exit ${result.exitCode}):\n'
        'stdout: ${result.stdout}\n'
        'stderr: ${result.stderr}',
      );
    }
    final stdout = (result.stdout as String).trim();
    if (stdout.isNotEmpty) _log.info('install-skills.sh (${dest.label}) stdout: $stdout');
    final stderr = (result.stderr as String).trim();
    if (stderr.isNotEmpty) _log.warning('install-skills.sh (${dest.label}) stderr: $stderr');

    // Defensive: AndThen's installer creates the Claude agents dir lazily,
    // only when iterating files in `plugin/agents/`. If upstream ever ships
    // an empty (or missing) `plugin/agents/`, the dir won't be created and
    // every restart would fail the completeness check, forcing a re-install
    // loop. Materializing it here keeps the gate stable across upstream
    // changes.
    Directory(dest.claudeAgentsDir).createSync(recursive: true);
  }

  Future<void> _copyDcNativeSkills(_InstallDestination dest) async {
    if (!Directory(dcNativeSkillsSourceDir).existsSync()) {
      throw SkillProvisionException(
        'DC-native skills source missing at $dcNativeSkillsSourceDir — '
        'check the bundled assets layout.',
      );
    }
    Directory(dest.skillsDir).createSync(recursive: true);
    Directory(dest.claudeSkillsDir).createSync(recursive: true);

    for (final name in dcNativeSkillNames) {
      final source = Directory(p.join(dcNativeSkillsSourceDir, name));
      if (!source.existsSync()) {
        throw SkillProvisionException('DC-native skill "$name" missing at ${source.path}');
      }
      await _copyDirectory(source, Directory(p.join(dest.skillsDir, name)));
      await _copyDirectory(source, Directory(p.join(dest.claudeSkillsDir, name)));
    }
  }

  Future<void> _writeMarker(_InstallDestination dest, String sha) async {
    final dir = Directory(dest.skillsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // Keep this as a parent-dir marker. If per-skill `.dartclaw-managed`
    // markers are added later, add regression coverage for SkillRegistryImpl's
    // data-dir source handling before changing this write path.
    final tmp = File('${dest.markerPath}.tmp');
    await tmp.writeAsString(sha, flush: true);
    await tmp.rename(dest.markerPath);
  }
}

Future<ProcessResult> _defaultProcessRunner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) {
  return Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    runInShell: false,
  );
}

Future<void> _defaultDirectoryCopier(Directory source, Directory destination) async {
  if (destination.existsSync()) {
    destination.deleteSync(recursive: true);
  }
  destination.createSync(recursive: true);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: source.path);
    final target = p.join(destination.path, relative);
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      Directory(p.dirname(target)).createSync(recursive: true);
      await entity.copy(target);
    }
  }
}

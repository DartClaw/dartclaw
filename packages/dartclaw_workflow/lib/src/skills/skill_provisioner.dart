import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show AndthenConfig, AndthenNetworkPolicy;
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

/// Marker filename written under the DartClaw data dir to record which AndThen
/// commit SHA the destination was last installed from.
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

/// Resolved data-dir native install destination.
class _InstallDestination {
  /// Codex-tier skills (`<dataDir>/.agents/skills`).
  final String skillsDir;

  /// Codex agents tier (`<dataDir>/.codex/agents`).
  final String codexAgentsDir;

  /// Claude Code skills tier (`<dataDir>/.claude/skills`).
  final String claudeSkillsDir;

  /// Claude Code agents tier (`<dataDir>/.claude/agents`).
  ///
  /// DartClaw materializes this directory after installer success so
  /// destination-completeness checks stay stable even when upstream ships no
  /// Claude agents.
  final String claudeAgentsDir;

  /// Human-friendly label used in logs/errors.
  final String label;

  const _InstallDestination({
    required this.skillsDir,
    required this.codexAgentsDir,
    required this.claudeSkillsDir,
    required this.claudeAgentsDir,
    required this.label,
  });

  String get markerPath => p.join(label, skillProvisionerMarkerFile);
}

/// Runtime provisioner for AndThen-derived workflow skills.
///
/// At `dartclaw serve` startup, [ensureCacheCurrent] clones AndThen into
/// its configured source cache, runs AndThen's own `scripts/install-skills.sh`
/// with explicit data-dir destination flags, and copies the DC-native skills
/// (`dartclaw-discover-project`, `dartclaw-validate-workflow`,
/// `dartclaw-merge-resolve`) into the same data-dir native skill trees. The
/// upstream installer also materializes Codex/Claude agent payloads in their
/// data-dir native agent directories.
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

  /// Clone-or-pull AndThen, then run the installer when the data-dir native
  /// destination marker SHA differs from the source HEAD or the tree is
  /// incomplete. Idempotent within a single process.
  Future<void> ensureCacheCurrent() async {
    final destinations = _resolveDestinations();
    final srcDir = config.sourceCacheDir?.trim().isNotEmpty == true
        ? config.sourceCacheDir!.trim()
        : p.join(dataDir, 'andthen-src');

    await _cloneOrPull(srcDir);

    final sha = await _currentSha(srcDir);
    if (sha.isEmpty) {
      throw const SkillProvisionException('Could not resolve AndThen source HEAD SHA after clone/pull.');
    }

    for (final dest in destinations) {
      if (await _destinationIsComplete(dest, sha, srcDir)) {
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
      throw SkillProvisionConfigException('andthen.git_url must use a hostname, not an IP literal: "$rawUrl".');
    }
  }

  // ── Internals (visible to tests via @visibleForTesting wrappers below) ────

  List<_InstallDestination> _resolveDestinations() {
    final normalizedDataDir = p.normalize(dataDir);
    final dataDirDest = _InstallDestination(
      label: normalizedDataDir,
      skillsDir: p.join(normalizedDataDir, '.agents', 'skills'),
      codexAgentsDir: p.join(normalizedDataDir, '.codex', 'agents'),
      claudeSkillsDir: p.join(normalizedDataDir, '.claude', 'skills'),
      claudeAgentsDir: p.join(normalizedDataDir, '.claude', 'agents'),
    );
    return [dataDirDest];
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
    // pinned. Tags, bare SHAs, and pre-staged sources without an `origin` remote
    // don't have an `origin/<ref>` form — fall back to the ref itself for them
    // (`git checkout` produces a detached HEAD or trusts the local branch).
    //
    // For `latest` specifically: when an `origin` remote IS configured but
    // `origin/main` is missing (upstream renamed default branch, history
    // rewrite + `fetch --prune`, partial fetch), silently falling back to
    // local `main` would mask upstream drift. Throw instead so the operator
    // notices. Pre-staged sources without an `origin` remote (test fixtures,
    // air-gapped setups) keep the local fallback because it's the only way
    // they can ever resolve `latest`.
    final localRef = isLatest ? 'main' : ref;
    final probe = await _runProcess('git', ['-C', srcDir, 'rev-parse', '--verify', '--quiet', 'origin/$localRef']);
    final String target;
    if (probe.exitCode == 0) {
      target = 'origin/$localRef';
    } else if (isLatest) {
      final hasOrigin = await _runProcess('git', ['-C', srcDir, 'remote', 'get-url', 'origin']);
      if (hasOrigin.exitCode == 0) {
        throw SkillProvisionException(
          'origin/$localRef not resolvable but origin remote is configured for $srcDir. '
          'The cached source may be stale (upstream history rewrite + `fetch --prune` removes pruned refs) '
          'or the upstream default branch was renamed. Refresh the cache or pin a specific ref.',
        );
      }
      target = localRef;
    } else {
      target = localRef;
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

  Future<bool> _destinationIsComplete(_InstallDestination dest, String sha, String srcDir) async {
    final markerFile = File(dest.markerPath);
    if (!markerFile.existsSync()) return false;

    final markerContents = (await markerFile.readAsString()).trim();
    if (markerContents != sha) return false;

    // `dartclaw-prd` is the canary skill. If upstream ever
    // renames or drops it, this check needs to follow.
    if (!File(p.join(dest.skillsDir, 'dartclaw-prd', 'SKILL.md')).existsSync()) return false;
    if (!File(p.join(dest.claudeSkillsDir, 'dartclaw-prd', 'SKILL.md')).existsSync()) return false;
    if (!Directory(dest.codexAgentsDir).existsSync()) return false;
    if (!Directory(dest.claudeAgentsDir).existsSync()) return false;
    final sourceAgentNames = await _sourceAgentNames(srcDir);
    for (final name in sourceAgentNames) {
      if (!File(p.join(dest.codexAgentsDir, 'dartclaw-$name.toml')).existsSync()) return false;
      if (!File(p.join(dest.claudeAgentsDir, 'dartclaw-$name.md')).existsSync()) return false;
    }

    for (final name in dcNativeSkillNames) {
      if (!File(p.join(dest.skillsDir, name, 'SKILL.md')).existsSync()) return false;
      if (!File(p.join(dest.claudeSkillsDir, name, 'SKILL.md')).existsSync()) return false;
    }
    return true;
  }

  Future<Set<String>> _sourceAgentNames(String srcDir) async {
    final source = Directory(p.join(srcDir, 'plugin', 'agents'));
    if (!source.existsSync()) {
      _log.warning('Source plugin/agents/ directory missing — no agent completeness verified for $srcDir');
      return const {};
    }

    // install-skills.sh copies plugin/agents/*.md to claude_agents_dir as .md
    // and generates the codex .toml from the same .md source. Only .md files
    // are agent payloads; mirror that exactly so completeness probes match
    // what the installer actually wrote.
    final names = <String>{};
    await for (final entity in source.list(followLinks: false)) {
      if (entity is! File) continue;
      if (p.extension(entity.path) != '.md') continue;

      names.add(p.basenameWithoutExtension(entity.path));
    }
    return names;
  }

  Future<void> _runInstallSkills(String srcDir, _InstallDestination dest) async {
    final script = p.join(srcDir, 'scripts', 'install-skills.sh');
    if (!File(script).existsSync()) {
      throw SkillProvisionException('install-skills.sh missing at $script — check andthen.ref/git_url.');
    }

    final args = <String>[
      '--prefix',
      'dartclaw-',
      '--display-brand',
      'DartClaw',
      '--skills-dir',
      dest.skillsDir,
      '--codex-agents-dir',
      dest.codexAgentsDir,
      '--claude-skills-dir',
      dest.claudeSkillsDir,
      '--claude-agents-dir',
      dest.claudeAgentsDir,
    ];

    final processEnv = identical(environment, Platform.environment) ? null : environment;
    var result = await _runProcess(script, args, workingDirectory: srcDir, environment: processEnv);
    var usedLegacyAgentFallback = false;
    if (result.exitCode != 0 && _installerRejectedAgentFlags(result.stderr)) {
      _log.warning(
        'install-skills.sh at $srcDir does not support explicit agent destination flags; '
        'retrying with data-dir skill destinations only.',
      );
      usedLegacyAgentFallback = true;
      result = await _runProcess(
        script,
        [
          '--prefix',
          'dartclaw-',
          '--display-brand',
          'DartClaw',
          '--skills-dir',
          dest.skillsDir,
          '--claude-skills-dir',
          dest.claudeSkillsDir,
        ],
        workingDirectory: srcDir,
        environment: processEnv,
      );
    }
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

    // Defensive: AndThen's installer creates agent dirs lazily when iterating
    // agent payloads. If upstream ever ships an empty agent set, these dirs
    // won't be created and every restart would fail the completeness check.
    Directory(dest.codexAgentsDir).createSync(recursive: true);
    Directory(dest.claudeAgentsDir).createSync(recursive: true);
    await _ensureAgentPayloads(srcDir, dest, overwrite: usedLegacyAgentFallback);
  }

  bool _installerRejectedAgentFlags(Object? stderr) {
    final text = (stderr as String?) ?? '';
    return text.contains('Unknown option: --codex-agents-dir') || text.contains('Unknown option: --claude-agents-dir');
  }

  Future<void> _ensureAgentPayloads(String srcDir, _InstallDestination dest, {required bool overwrite}) async {
    final sourceDir = Directory(p.join(srcDir, 'plugin', 'agents'));
    if (!sourceDir.existsSync()) return;

    await for (final source in sourceDir.list(followLinks: false)) {
      if (source is! File || p.extension(source.path) != '.md') continue;

      final baseName = p.basenameWithoutExtension(source.path);
      final prefixedName = 'dartclaw-$baseName';
      final markdown = await source.readAsString();
      final parsed = _parseAgentMarkdown(markdown, defaultName: baseName);

      final claudeAgent = File(p.join(dest.claudeAgentsDir, '$prefixedName.md'));
      if (overwrite || !claudeAgent.existsSync()) {
        claudeAgent.parent.createSync(recursive: true);
        await claudeAgent.writeAsString(_renderClaudeAgent(markdown, prefixedName));
      }

      final codexAgent = File(p.join(dest.codexAgentsDir, '$prefixedName.toml'));
      if (overwrite || !codexAgent.existsSync()) {
        codexAgent.parent.createSync(recursive: true);
        await codexAgent.writeAsString(_renderCodexAgent(parsed, prefixedName));
      }
    }
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
      for (final destPath in [p.join(dest.skillsDir, name), p.join(dest.claudeSkillsDir, name)]) {
        if (Directory(destPath).existsSync()) {
          _log.warning('Overwriting $destPath — any manual changes to this DC-native skill will be lost.');
        }
        await _copyDirectory(source, Directory(destPath));
      }
    }
  }

  Future<void> _writeMarker(_InstallDestination dest, String sha) async {
    final dir = Directory(dest.skillsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // Keep this as a parent-dir marker so refresh bookkeeping stays outside
    // upstream-owned skill directories.
    final tmp = File('${dest.markerPath}.tmp');
    await tmp.writeAsString(sha, flush: true);
    await tmp.rename(dest.markerPath);
  }
}

_AgentMarkdown _parseAgentMarkdown(String markdown, {required String defaultName}) {
  final normalized = markdown.replaceAll('\r\n', '\n');
  if (!normalized.startsWith('---\n')) {
    return _AgentMarkdown(
      frontmatterLines: const [],
      body: normalized.trimLeft(),
      name: defaultName,
      description: '',
      model: null,
    );
  }

  final closeIndex = normalized.indexOf('\n---\n', 4);
  if (closeIndex < 0) {
    return _AgentMarkdown(
      frontmatterLines: const [],
      body: normalized.trimLeft(),
      name: defaultName,
      description: '',
      model: null,
    );
  }

  final frontmatter = normalized.substring(4, closeIndex).split('\n');
  final body = normalized.substring(closeIndex + 5).trimLeft();
  final fields = <String, String>{};
  for (final line in frontmatter) {
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    fields[line.substring(0, separator).trim()] = line.substring(separator + 1).trim();
  }

  return _AgentMarkdown(
    frontmatterLines: frontmatter,
    body: body,
    name: fields['name']?.isNotEmpty == true ? fields['name']! : defaultName,
    description: fields['description'] ?? '',
    model: fields['model'],
  );
}

String _renderClaudeAgent(String sourceMarkdown, String prefixedName) {
  final parsed = _parseAgentMarkdown(sourceMarkdown, defaultName: prefixedName);
  if (parsed.frontmatterLines.isEmpty) {
    return '---\nname: $prefixedName\n---\n\n${parsed.body}';
  }

  var sawName = false;
  final frontmatter = <String>[];
  for (final line in parsed.frontmatterLines) {
    if (line.trimLeft().startsWith('name:')) {
      frontmatter.add('name: $prefixedName');
      sawName = true;
    } else {
      frontmatter.add(line);
    }
  }
  if (!sawName) frontmatter.insert(0, 'name: $prefixedName');
  return '---\n${frontmatter.join('\n')}\n---\n\n${parsed.body}';
}

String _renderCodexAgent(_AgentMarkdown agent, String prefixedName) {
  final model = _codexAgentModel(agent.model);
  return [
    '# Generated by DartClaw from plugin/agents/${agent.name}.md',
    '# Do not edit by hand — edit the source .md instead.',
    '',
    'name = ${jsonEncode(prefixedName)}',
    'description = ${jsonEncode(agent.description)}',
    'model = ${jsonEncode(model.model)}',
    'model_reasoning_effort = ${jsonEncode(model.reasoningEffort)}',
    '',
    'developer_instructions = ${jsonEncode(agent.body.trim())}',
    '',
  ].join('\n');
}

({String model, String reasoningEffort}) _codexAgentModel(String? sourceModel) {
  final normalized = sourceModel?.trim().toLowerCase();
  if (normalized == 'haiku') {
    return (model: 'gpt-5-mini', reasoningEffort: 'low');
  }
  if (normalized != null && normalized.startsWith('gpt-')) {
    return (model: normalized, reasoningEffort: 'medium');
  }
  return (model: 'gpt-5', reasoningEffort: 'medium');
}

final class _AgentMarkdown {
  final List<String> frontmatterLines;
  final String body;
  final String name;
  final String description;
  final String? model;

  const _AgentMarkdown({
    required this.frontmatterLines,
    required this.body,
    required this.name,
    required this.description,
    required this.model,
  });
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

import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart' show OutputConfig, SkillInfo, SkillSource;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'skill_registry.dart';

/// Filesystem-backed implementation of [SkillRegistry].
///
/// Scans prioritized source directories for Agent Skills-compatible
/// definitions (SKILL.md with YAML frontmatter). Non-recursive scan,
/// metadata only (~100 tokens per skill).
///
/// Deduplication: same name across sources -> highest priority wins,
/// merge harness sets.
class SkillRegistryImpl implements SkillRegistry {
  static final _log = Logger('SkillRegistry');

  /// Maximum SKILL.md file size (512KB) — reject larger files.
  static const _maxFileSize = 512 * 1024;

  /// Executable file extensions to warn about.
  static const _executableExtensions = {'.sh', '.py', '.ps1', '.bat', '.cmd'};

  /// Discovered skills keyed by name (post-deduplication).
  final Map<String, SkillInfo> _skills = {};

  /// Discovers skills from all configured source directories.
  ///
  /// Sources are scanned in priority order (P1-P7). For each skill name,
  /// the highest-priority source wins, and harness sets are merged across
  /// sources that contain the same skill.
  ///
  /// [projectDir] — single active project directory (legacy shorthand for
  /// P1-P2 resolution).
  /// [projectDirs] — project directories to scan in priority order for P1-P2.
  /// [workspaceDir] — DartClaw workspace directory (for P3).
  /// [dataDir] — DartClaw data directory (for P5).
  /// [pluginDirs] — additional plugin skill directories (for P6).
  void discover({
    String? projectDir,
    Iterable<String> projectDirs = const [],
    required String workspaceDir,
    required String dataDir,
    List<String> pluginDirs = const [],
    String? userClaudeSkillsDir,
    String? userAgentsSkillsDir,
    String? builtInSkillsDir,
  }) {
    final stopwatch = Stopwatch()..start();
    _skills.clear();

    final orderedProjectDirs = <String>[
      ...switch (projectDir) {
        final dir? => [dir],
        null => const <String>[],
      },
      for (final dir in projectDirs)
        if (dir != projectDir) dir,
    ];

    // Build source list in priority order (P1 highest).
    final sources = <(String, SkillSource, Set<String>)>[
      for (final dir in orderedProjectDirs) ...[
        // P1: <projectDir>/.claude/skills/ -> nativeHarnesses: {claude}
        (p.join(dir, '.claude', 'skills'), SkillSource.projectClaude, <String>{'claude'}),
        // P2: <projectDir>/.agents/skills/ -> nativeHarnesses: {codex}
        (p.join(dir, '.agents', 'skills'), SkillSource.projectAgents, <String>{'codex'}),
      ],
      // P3: <workspace>/skills/ -> nativeHarnesses: {} (DartClaw-managed)
      (p.join(workspaceDir, 'skills'), SkillSource.workspace, <String>{}),
      // P4: ~/.claude/skills/ -> nativeHarnesses: {claude}
      (userClaudeSkillsDir ?? _userClaudeSkillsDir, SkillSource.userClaude, <String>{'claude'}),
      // P5: ~/.agents/skills/ -> nativeHarnesses: {codex}
      (userAgentsSkillsDir ?? _userAgentsSkillsDir, SkillSource.userAgents, <String>{'codex'}),
      // P6: <dataDir>/skills/ -> nativeHarnesses: {} (DartClaw-managed)
      (p.join(dataDir, 'skills'), SkillSource.userDartclaw, <String>{}),
      // P7: <repo>/packages/dartclaw_workflow/skills/ -> repo-managed built-ins.
      if (builtInSkillsDir != null) (builtInSkillsDir, SkillSource.dartclaw, <String>{}),
      // P8: Plugin directories -> nativeHarnesses: {} (plugin-dependent)
      for (final dir in pluginDirs) (dir, SkillSource.plugin, <String>{}),
    ];

    for (final (dirPath, source, harnesses) in sources) {
      _scanDirectory(dirPath, source, harnesses);
    }

    stopwatch.stop();
    _log.info(
      'Skill discovery: ${_skills.length} skills from '
      '${sources.length} sources in ${stopwatch.elapsedMilliseconds}ms',
    );
  }

  /// Path to `~/.claude/skills/`.
  static String get _userClaudeSkillsDir =>
      p.join(Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '/tmp', '.claude', 'skills');

  /// Path to `~/.agents/skills/`.
  static String get _userAgentsSkillsDir =>
      p.join(Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '/tmp', '.agents', 'skills');

  void _scanDirectory(String dirPath, SkillSource source, Set<String> harnesses) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return;

    // Non-recursive: each immediate subdirectory is a skill.
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (e) {
      _log.warning('Failed to list skill directory $dirPath: $e');
      return;
    }

    for (final entry in entries) {
      if (entry is! Directory) continue;

      // Security: block symlinks.
      if (FileSystemEntity.isLinkSync(entry.path)) {
        _log.warning('Skill directory is a symlink, skipping: ${entry.path}');
        continue;
      }

      final skillDir = entry.path;
      if (_skipsManagedCopies(source) && _hasManagedMarker(skillDir)) {
        _log.fine('Managed skill copy detected in ${source.displayName}, skipping: $skillDir');
        continue;
      }
      final skillMdPath = p.join(skillDir, 'SKILL.md');
      final skillMdFile = File(skillMdPath);

      if (!skillMdFile.existsSync()) {
        _log.fine('No SKILL.md in $skillDir, skipping');
        continue;
      }

      // Security: block symlinked SKILL.md.
      if (FileSystemEntity.isLinkSync(skillMdPath)) {
        _log.warning('SKILL.md is a symlink, skipping: $skillMdPath');
        continue;
      }

      // Security: reject >512KB.
      final fileSize = skillMdFile.lengthSync();
      if (fileSize > _maxFileSize) {
        _log.warning(
          'SKILL.md exceeds ${_maxFileSize ~/ 1024}KB ($fileSize bytes), '
          'skipping: $skillMdPath',
        );
        continue;
      }

      // Security: warn on executables in skill directory.
      _warnOnExecutables(skillDir);

      // Parse frontmatter.
      final info = _parseFrontmatterContent(
        skillMdFile.readAsStringSync(),
        skillDir,
        p.basename(skillDir),
        source,
        harnesses,
      );
      if (info == null) continue;

      // Deduplication: same name -> highest priority wins, merge harnesses.
      final existing = _skills[info.name];
      if (existing != null) {
        // Merge harness sets from lower-priority duplicate.
        _skills[info.name] = existing.mergeHarnesses(info.nativeHarnesses);
        _log.fine(
          'Skill "${info.name}" already discovered from '
          '${existing.source.displayName}, merging harnesses from '
          '${source.displayName}',
        );
      } else {
        _skills[info.name] = info;
      }
    }
  }

  bool _skipsManagedCopies(SkillSource source) => switch (source) {
    SkillSource.projectClaude || SkillSource.projectAgents || SkillSource.userClaude || SkillSource.userAgents => true,
    _ => false,
  };

  bool _hasManagedMarker(String skillDir) {
    return File(p.join(skillDir, '.dartclaw-managed')).existsSync();
  }

  void _warnOnExecutables(String skillDir) {
    try {
      final entries = Directory(skillDir).listSync(followLinks: false);
      for (final entry in entries) {
        if (entry is! File) continue;
        final ext = p.extension(entry.path).toLowerCase();
        if (_executableExtensions.contains(ext)) {
          _log.warning('Skill directory contains executable: ${entry.path}');
        }
      }
    } catch (_) {
      // Best-effort audit.
    }
  }

  /// Parses YAML frontmatter from a SKILL.md file or in-memory content.
  ///
  /// Frontmatter is delimited by `---` lines at the start of the file.
  /// Extracts `name` and `description` fields per Agent Skills spec plus the
  /// optional `workflow:` block carrying `default_prompt`, `default_outputs`,
  /// and `emits_own_outcome`
  /// (DartClaw extension — third-party skills without the block are unaffected).
  /// Falls back to directory name for `name` if missing.
  SkillInfo? _parseFrontmatterContent(
    String content,
    String skillPath,
    String fallbackName,
    SkillSource source,
    Set<String> harnesses,
  ) {
    try {
      String? name;
      String description = '';
      String? defaultPrompt;
      Map<String, OutputConfig>? defaultOutputs;
      bool emitsOwnOutcome = false;

      if (content.startsWith('---')) {
        final endIndex = content.indexOf('\n---', 3);
        if (endIndex > 0) {
          final yamlStr = content.substring(4, endIndex);
          final yaml = loadYaml(yamlStr);
          if (yaml is YamlMap) {
            name = yaml['name'] as String?;
            description = (yaml['description'] as String?) ?? '';
            final workflowBlock = yaml['workflow'];
            if (workflowBlock is YamlMap) {
              (defaultPrompt, defaultOutputs, emitsOwnOutcome) = _parseWorkflowFrontmatterBlock(
                workflowBlock,
                skillPath,
              );
            } else if (workflowBlock != null) {
              _log.warning('SKILL.md `workflow:` block is not a map in $skillPath; ignoring');
            }
          }
        }
      }

      // Fall back to directory name if frontmatter name is missing or empty.
      if (name == null || name.isEmpty) name = fallbackName;

      return SkillInfo(
        name: name,
        description: description,
        source: source,
        path: skillPath,
        nativeHarnesses: harnesses,
        defaultPrompt: defaultPrompt,
        defaultOutputs: defaultOutputs,
        emitsOwnOutcome: emitsOwnOutcome,
      );
    } catch (e) {
      _log.warning('Failed to parse SKILL.md in $skillPath: $e');
      return null;
    }
  }

  /// Parses the optional `workflow:` frontmatter block.
  ///
  /// Returns `(defaultPrompt, defaultOutputs, emitsOwnOutcome)`. Malformed entries are logged at
  /// warning level and yield null for that field so skill discovery keeps
  /// working for minimally-declared third-party skills.
  (String?, Map<String, OutputConfig>?, bool) _parseWorkflowFrontmatterBlock(YamlMap block, String skillPath) {
    String? defaultPrompt;
    Map<String, OutputConfig>? defaultOutputs;
    var emitsOwnOutcome = false;

    final rawPrompt = block['default_prompt'];
    if (rawPrompt is String) {
      defaultPrompt = rawPrompt;
    } else if (rawPrompt != null) {
      _log.warning('SKILL.md `workflow.default_prompt` is not a string in $skillPath; ignoring');
    }

    final rawOutputs = block['default_outputs'];
    if (rawOutputs is YamlMap) {
      final parsed = <String, OutputConfig>{};
      for (final entry in rawOutputs.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String) {
          _log.warning('SKILL.md `workflow.default_outputs` has non-string key in $skillPath; skipping');
          continue;
        }
        if (value is! YamlMap) {
          _log.warning('SKILL.md `workflow.default_outputs.$key` is not a map in $skillPath; skipping');
          continue;
        }
        try {
          parsed[key] = OutputConfig.fromJson(_yamlToDart(value) as Map<String, dynamic>);
        } catch (e) {
          _log.warning('SKILL.md `workflow.default_outputs.$key` is invalid in $skillPath: $e');
        }
      }
      if (parsed.isNotEmpty) defaultOutputs = parsed;
    } else if (rawOutputs != null) {
      _log.warning('SKILL.md `workflow.default_outputs` is not a map in $skillPath; ignoring');
    }

    final rawEmitsOwnOutcome = block['emits_own_outcome'];
    if (rawEmitsOwnOutcome is bool) {
      emitsOwnOutcome = rawEmitsOwnOutcome;
    } else if (rawEmitsOwnOutcome != null) {
      _log.warning('SKILL.md `workflow.emits_own_outcome` is not a boolean in $skillPath; ignoring');
    }

    return (defaultPrompt, defaultOutputs, emitsOwnOutcome);
  }

  /// Recursively converts YAML-native nodes to plain Dart types so they plug
  /// into `OutputConfig.fromJson` (which expects `Map<String, dynamic>` /
  /// `List<dynamic>` rather than `YamlMap` / `YamlList`).
  Object? _yamlToDart(Object? node) {
    if (node is YamlMap) {
      return <String, dynamic>{for (final entry in node.entries) entry.key.toString(): _yamlToDart(entry.value)};
    }
    if (node is YamlList) {
      return [for (final item in node) _yamlToDart(item)];
    }
    return node;
  }

  // ── SkillRegistry interface ──────────────────────────────────────────────

  @override
  List<SkillInfo> listAll() => _skills.values.toList(growable: false);

  @override
  SkillInfo? getByName(String name) => _skills[name];

  // Install hint appended when an andthen-* skill ref is missing.
  static const _andthenInstallHint =
      'Install AndThen skills (>= 0.14.3 required) by running scripts/install-skills.sh '
      'from an AndThen checkout — see https://github.com/IT-HUSET/andthen.';

  @override
  String? validateRef(String skillRef) {
    if (_skills.containsKey(skillRef)) return null;

    // Build suggestion list from available skills.
    final available = _skills.keys.toList()..sort();

    final isAndthenRef = skillRef.startsWith('andthen-');
    final installSuffix = isAndthenRef ? ' $_andthenInstallHint' : '';

    if (available.isEmpty) {
      return 'Skill "$skillRef" not found. No skills discovered.$installSuffix';
    }

    // Simple prefix/substring match for suggestions.
    final suggestions = available.where((n) => n.contains(skillRef) || skillRef.contains(n)).take(5).toList();

    if (suggestions.isNotEmpty) {
      return 'Skill "$skillRef" not found. '
          'Did you mean: ${suggestions.join(', ')}? '
          'Available: ${available.join(', ')}$installSuffix';
    }

    return 'Skill "$skillRef" not found. '
        'Available skills: ${available.join(', ')}$installSuffix';
  }

  @override
  bool isNativeFor(String skillName, String harnessType) {
    final skill = _skills[skillName];
    if (skill == null) return false;
    return skill.nativeHarnesses.contains(harnessType);
  }
}

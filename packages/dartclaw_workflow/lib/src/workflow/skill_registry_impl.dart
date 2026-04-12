import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart' show SkillInfo, SkillSource;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../embedded_skills.dart';
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

    if (builtInSkillsDir == null && embeddedSkills.isNotEmpty) {
      _scanEmbeddedSkills();
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

  void _scanEmbeddedSkills() {
    final entries = embeddedSkills.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in entries) {
      final skillMd = entry.value['SKILL.md'];
      if (skillMd == null) {
        _log.fine('No embedded SKILL.md for ${entry.key}, skipping');
        continue;
      }

      final info = _parseFrontmatterContent(
        skillMd,
        'embedded',
        entry.key,
        SkillSource.dartclaw,
        _embeddedNativeHarnesses(entry.value),
      );
      if (info == null) continue;

      final existing = _skills[info.name];
      if (existing != null) {
        _skills[info.name] = existing.mergeHarnesses(info.nativeHarnesses);
        _log.fine(
          'Skill "${info.name}" already discovered from '
          '${existing.source.displayName}, merging harnesses from embedded built-ins',
        );
      } else {
        _skills[info.name] = info;
      }
    }
  }

  Set<String> _embeddedNativeHarnesses(Map<String, String> files) {
    // Embedded built-ins are shipped with agent manifests under `agents/`.
    // In the standalone build they are materialized for the first-class
    // Claude and Codex harness roots, so discovery should preserve both IDs.
    if (files.keys.any((path) => path.startsWith('agents/'))) {
      return <String>{'claude', 'codex'};
    }
    return const <String>{};
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
  /// Extracts `name` and `description` fields per Agent Skills spec.
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

      if (content.startsWith('---')) {
        final endIndex = content.indexOf('\n---', 3);
        if (endIndex > 0) {
          final yamlStr = content.substring(4, endIndex);
          final yaml = loadYaml(yamlStr);
          if (yaml is YamlMap) {
            name = yaml['name'] as String?;
            description = (yaml['description'] as String?) ?? '';
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
      );
    } catch (e) {
      _log.warning('Failed to parse SKILL.md in $skillPath: $e');
      return null;
    }
  }

  // ── SkillRegistry interface ──────────────────────────────────────────────

  @override
  List<SkillInfo> listAll() => _skills.values.toList(growable: false);

  @override
  SkillInfo? getByName(String name) => _skills[name];

  @override
  String? validateRef(String skillRef) {
    if (_skills.containsKey(skillRef)) return null;

    // Build suggestion list from available skills.
    final available = _skills.keys.toList()..sort();
    if (available.isEmpty) {
      return 'Skill "$skillRef" not found. No skills discovered.';
    }

    // Simple prefix/substring match for suggestions.
    final suggestions = available.where((n) => n.contains(skillRef) || skillRef.contains(n)).take(5).toList();

    if (suggestions.isNotEmpty) {
      return 'Skill "$skillRef" not found. '
          'Did you mean: ${suggestions.join(', ')}? '
          'Available: ${available.join(', ')}';
    }

    return 'Skill "$skillRef" not found. '
        'Available skills: ${available.join(', ')}';
  }

  @override
  bool isNativeFor(String skillName, String harnessType) {
    final skill = _skills[skillName];
    if (skill == null) return false;
    return skill.nativeHarnesses.contains(harnessType);
  }
}

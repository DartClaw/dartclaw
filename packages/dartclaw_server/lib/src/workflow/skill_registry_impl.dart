import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show SkillRegistry;
import 'package:dartclaw_models/dartclaw_models.dart'
    show SkillInfo, SkillSource;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Filesystem-backed implementation of [SkillRegistry].
///
/// Scans 6 prioritized source directories for Agent Skills-compatible
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
  /// Sources are scanned in priority order (P1-P6). For each skill name,
  /// the highest-priority source wins, and harness sets are merged across
  /// sources that contain the same skill.
  ///
  /// [projectDir] — active project directory (for P1-P2 resolution).
  /// [workspaceDir] — DartClaw workspace directory (for P3).
  /// [dataDir] — DartClaw data directory (for P5).
  /// [pluginDirs] — additional plugin skill directories (for P6).
  void discover({
    String? projectDir,
    required String workspaceDir,
    required String dataDir,
    List<String> pluginDirs = const [],
    String? userClaudeSkillsDir,
  }) {
    final stopwatch = Stopwatch()..start();
    _skills.clear();

    // Build source list in priority order (P1 highest).
    final sources = <(String, SkillSource, Set<String>)>[
      // P1: <projectDir>/.claude/skills/ -> nativeHarnesses: {claude}
      if (projectDir != null)
        (p.join(projectDir, '.claude', 'skills'), SkillSource.projectClaude, <String>{'claude'}),
      // P2: <projectDir>/.agents/skills/ -> nativeHarnesses: {codex}
      if (projectDir != null)
        (p.join(projectDir, '.agents', 'skills'), SkillSource.projectCodex, <String>{'codex'}),
      // P3: <workspace>/skills/ -> nativeHarnesses: {} (DartClaw-managed)
      (p.join(workspaceDir, 'skills'), SkillSource.workspace, <String>{}),
      // P4: ~/.claude/skills/ -> nativeHarnesses: {claude}
      (userClaudeSkillsDir ?? _userClaudeSkillsDir, SkillSource.userClaude, <String>{'claude'}),
      // P5: <dataDir>/skills/ -> nativeHarnesses: {} (DartClaw-managed)
      (p.join(dataDir, 'skills'), SkillSource.userDartclaw, <String>{}),
      // P6: Plugin directories -> nativeHarnesses: {} (plugin-dependent)
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
      p.join(Platform.environment['HOME'] ?? '/tmp', '.claude', 'skills');

  void _scanDirectory(
    String dirPath,
    SkillSource source,
    Set<String> harnesses,
  ) {
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
      final info = _parseFrontmatter(skillMdFile, skillDir, source, harnesses);
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

  /// Parses YAML frontmatter from a SKILL.md file.
  ///
  /// Frontmatter is delimited by `---` lines at the start of the file.
  /// Extracts `name` and `description` fields per Agent Skills spec.
  /// Falls back to directory name for `name` if missing.
  SkillInfo? _parseFrontmatter(
    File file,
    String skillDir,
    SkillSource source,
    Set<String> harnesses,
  ) {
    try {
      final content = file.readAsStringSync();
      final dirName = p.basename(skillDir);

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
      if (name == null || name.isEmpty) name = dirName;

      return SkillInfo(
        name: name,
        description: description,
        source: source,
        path: skillDir,
        nativeHarnesses: harnesses,
      );
    } catch (e) {
      _log.warning('Failed to parse SKILL.md in $skillDir: $e');
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
    final suggestions = available
        .where((n) => n.contains(skillRef) || skillRef.contains(n))
        .take(5)
        .toList();

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

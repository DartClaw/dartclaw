import 'dart:convert';
import 'dart:io';

const _expectedTemplates = [
  'error_page',
  'login',
  'components',
  'layout',
  'topbar',
  'sidebar',
  'session_info',
  'scheduling',
  'health_dashboard',
  'settings',
  'chat',
  'whatsapp_pairing',
  'signal_pairing',
  'memory_dashboard',
  'restart_banner',
  'channel_detail',
  'tasks',
  'task_detail',
  'task_timeline',
  'projects',
  'canvas_standalone',
  'canvas_embed',
  'canvas_admin_panel',
  'canvas_task_board',
  'canvas_stats_bar',
  'workflow_detail',
  'workflow_step_detail',
  'workflow_list',
];

const _expectedSkills = [
  'dartclaw-discover-project',
  'dartclaw-exec-spec',
  'dartclaw-plan',
  'dartclaw-refactor',
  'dartclaw-remediate-findings',
  'dartclaw-review-code',
  'dartclaw-review-doc',
  'dartclaw-review-gap',
  'dartclaw-spec',
  'dartclaw-update-state',
];

void main() {
  final root = Directory.current.path;
  try {
    final templateDir = Directory(_join(root, 'packages/dartclaw_server/lib/src/templates'));
    final staticDir = Directory(_join(root, 'packages/dartclaw_server/lib/src/static'));
    final skillsDir = Directory(_join(root, 'packages/dartclaw_workflow/skills'));
    final embeddedAssetsFile = File(_join(root, 'packages/dartclaw_server/lib/src/embedded_assets.dart'));
    final embeddedSkillsFile = File(_join(root, 'packages/dartclaw_workflow/lib/src/embedded_skills.dart'));

    _requireDirectory(templateDir, 'templates directory');
    _requireDirectory(staticDir, 'static assets directory');
    _requireDirectory(skillsDir, 'skills directory');
    _requireFile(embeddedAssetsFile, 'embedded assets stub');
    _requireFile(embeddedSkillsFile, 'embedded skills stub');

    final templateSources = _collectTemplates(templateDir);
    final staticAssets = _collectStaticAssets(staticDir);
    final skillSources = _collectSkills(skillsDir);

    final errors = <String>[];
    errors.addAll(_validateExpectedInventory('template', _expectedTemplates, templateSources.keys.toList()));
    errors.addAll(_validateExpectedInventory('skill', _expectedSkills, skillSources.keys.toList()));
    errors.addAll(_validateStaticInventory(staticAssets.keys.toList()));

    if (errors.isNotEmpty) {
      throw _BuildFailure(errors);
    }

    _writeAtomically(embeddedAssetsFile, _renderEmbeddedAssets(templateSources, staticAssets));
    _writeAtomically(embeddedSkillsFile, _renderEmbeddedSkills(skillSources));
  } on _BuildFailure catch (error) {
    for (final line in error.messages) {
      stderr.writeln(line);
    }
    exitCode = 1;
  } on FileSystemException catch (error) {
    stderr.writeln('ERROR: ${error.message}${error.path == null ? '' : ' (${error.path})'}');
    exitCode = 1;
  } catch (error) {
    stderr.writeln('ERROR: $error');
    exitCode = 1;
  }
}

Map<String, String> _collectTemplates(Directory templateDir) {
  final files = <String, String>{};
  for (final entity in templateDir.listSync(followLinks: false)) {
    if (entity is! File) continue;
    if (!entity.path.endsWith('.html')) continue;
    final name = _basenameWithoutHtml(entity.path);
    files[name] = base64Encode(utf8.encode(entity.readAsStringSync()));
  }

  return Map<String, String>.fromEntries(files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
}

Map<String, String> _collectStaticAssets(Directory staticDir) {
  final assets = <String, String>{};
  for (final entity in staticDir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final relativePath = _relativePath(entity.path, staticDir.path);
    if (relativePath == 'VENDORS.md') continue;
    assets[relativePath] = base64Encode(entity.readAsBytesSync());
  }

  return Map<String, String>.fromEntries(assets.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
}

Map<String, Map<String, String>> _collectSkills(Directory skillsDir) {
  final skills = <String, Map<String, String>>{};

  for (final entity in skillsDir.listSync(followLinks: false)) {
    if (entity is! Directory) continue;
    final name = _basename(entity.path);
    final skillMd = File(_join(entity.path, 'SKILL.md'));
    if (!skillMd.existsSync()) {
      continue;
    }

    final files = <String, String>{};
    for (final item in entity.listSync(recursive: true, followLinks: false)) {
      if (item is! File) continue;
      final relativePath = _relativePath(item.path, entity.path);
      files[relativePath] = base64Encode(item.readAsBytesSync());
    }

    skills[name] = Map<String, String>.fromEntries(files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }

  return Map<String, Map<String, String>>.fromEntries(skills.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
}

List<String> _validateExpectedInventory(String kind, List<String> expected, List<String> actual) {
  final expectedSet = expected.toSet();
  final actualSet = actual.toSet();
  final missing = expectedSet.difference(actualSet).toList()..sort();
  final unexpected = actualSet.difference(expectedSet).toList()..sort();
  final errors = <String>[];

  if (missing.isNotEmpty) {
    errors.add('Missing $kind${missing.length == 1 ? '' : 's'}: ${missing.join(', ')}');
  }
  if (unexpected.isNotEmpty) {
    errors.add('Unexpected $kind${unexpected.length == 1 ? '' : 's'}: ${unexpected.join(', ')}');
  }

  return errors;
}

List<String> _validateStaticInventory(List<String> actual) {
  final expected = <String>[
    'app.js',
    'components.css',
    'hljs-catppuccin-latte.css',
    'hljs-catppuccin-mocha.css',
    'hljs-dart.min.js',
    'hljs.min.js',
    'icons.css',
    'memory.js',
    'purify.min.js',
    'scheduling.js',
    'settings.js',
    'sse.js',
    'tokens.css',
    'whatsapp.js',
  ];
  return _validateExpectedInventory('static asset', expected, actual);
}

String _renderEmbeddedAssets(Map<String, String> templates, Map<String, String> staticAssets) {
  final buffer = StringBuffer()
    ..writeln("import 'dart:convert';")
    ..writeln()
    ..writeln('const _encodedTemplates = <String, String>{');
  for (final entry in templates.entries) {
    buffer.writeln('  ${jsonEncode(entry.key)}: ${jsonEncode(entry.value)},');
  }
  buffer
    ..writeln('};')
    ..writeln('const _encodedStaticAssets = <String, String>{');
  for (final entry in staticAssets.entries) {
    buffer.writeln('  ${jsonEncode(entry.key)}: ${jsonEncode(entry.value)},');
  }
  buffer
    ..writeln('};')
    ..writeln('const embeddedStaticMimeTypes = <String, String>{');
  for (final entry in staticAssets.entries) {
    buffer.writeln('  ${jsonEncode(entry.key)}: ${jsonEncode(_mimeTypeFor(entry.key))},');
  }
  buffer
    ..writeln('};')
    ..writeln()
    ..writeln('final Map<String, String> embeddedTemplates = {')
    ..writeln('  for (final entry in _encodedTemplates.entries) entry.key: utf8.decode(base64Decode(entry.value)),')
    ..writeln('};')
    ..writeln()
    ..writeln('final Map<String, List<int>> embeddedStaticAssets = {')
    ..writeln('  for (final entry in _encodedStaticAssets.entries) entry.key: base64Decode(entry.value),')
    ..writeln('};');
  return buffer.toString();
}

String _renderEmbeddedSkills(Map<String, Map<String, String>> skills) {
  final buffer = StringBuffer()
    ..writeln("import 'dart:convert';")
    ..writeln()
    ..writeln('const _encodedSkills = <String, Map<String, String>>{');
  for (final entry in skills.entries) {
    buffer.writeln('  ${jsonEncode(entry.key)}: <String, String>{');
    for (final file in entry.value.entries) {
      buffer.writeln('    ${jsonEncode(file.key)}: ${jsonEncode(file.value)},');
    }
    buffer.writeln('  },');
  }
  buffer
    ..writeln('};')
    ..writeln()
    ..writeln('final Map<String, Map<String, String>> embeddedSkills = {')
    ..writeln(
      '  for (final skill in _encodedSkills.entries) skill.key: {for (final file in skill.value.entries) file.key: utf8.decode(base64Decode(file.value))},',
    )
    ..writeln('};');
  return buffer.toString();
}

String _mimeTypeFor(String relativePath) {
  if (relativePath.endsWith('.js')) {
    return 'application/javascript';
  }
  if (relativePath.endsWith('.css')) {
    return 'text/css';
  }
  throw StateError('Unsupported static asset type: $relativePath');
}

void _requireDirectory(Directory directory, String description) {
  if (!directory.existsSync()) {
    throw StateError('Missing $description: ${directory.path}');
  }
}

void _requireFile(File file, String description) {
  if (!file.existsSync()) {
    throw StateError('Missing $description: ${file.path}');
  }
}

String _join(String left, String right) => '$left/$right';

String _basename(String path) => path.split('/').where((segment) => segment.isNotEmpty).last;

String _basenameWithoutHtml(String path) {
  final name = _basename(path);
  if (!name.endsWith('.html')) return name;
  return name.substring(0, name.length - 5);
}

String _relativePath(String path, String root) {
  final normalizedPath = path.replaceAll('\\', '/');
  final normalizedRoot = root.replaceAll('\\', '/');
  if (normalizedPath == normalizedRoot) return '';
  final prefix = normalizedRoot.endsWith('/') ? normalizedRoot : '$normalizedRoot/';
  if (!normalizedPath.startsWith(prefix)) {
    throw StateError('Path is not under root: $path (root: $root)');
  }
  return normalizedPath.substring(prefix.length);
}

void _writeAtomically(File file, String content) {
  final tmp = File('${file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}');
  tmp.writeAsStringSync(content);
  if (file.existsSync()) {
    file.deleteSync();
  }
  tmp.renameSync(file.path);
}

class _BuildFailure implements Exception {
  final List<String> messages;

  _BuildFailure(this.messages);
}

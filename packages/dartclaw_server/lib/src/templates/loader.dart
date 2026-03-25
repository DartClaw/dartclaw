import 'dart:io';

import 'package:meta/meta.dart';
import 'package:trellis/trellis.dart';

/// Expected template files that must exist for the server to start.
const expectedTemplates = [
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
];

TemplateLoaderService? _templateLoader;

/// Global template loader, initialized at startup via [initTemplates].
///
/// Reads all `.html` template files once at init, then serves them as
/// in-memory source strings for synchronous Trellis rendering.
/// Throws [StateError] if accessed before [initTemplates] is called.
TemplateLoaderService get templateLoader {
  final loader = _templateLoader;
  if (loader == null) {
    throw StateError('templateLoader not initialized — call initTemplates() first');
  }
  return loader;
}

/// Initializes the global [templateLoader] from `.html` files in [basePath].
///
/// Must be called once before any template rendering (typically in
/// `ServeCommand.run`). When [devMode] is true, templates are re-read from
/// disk on each render so changes take effect without a server restart.
/// Throws [StateError] on missing or empty templates.
void initTemplates(String basePath, {bool devMode = false}) {
  _templateLoader = TemplateLoaderService(basePath, devMode: devMode);
  _templateLoader!.validate();
}

/// Resets the global template loader to uninitialized state.
///
/// Only for use in tests to ensure isolation between test suites.
@visibleForTesting
void resetTemplates() {
  _templateLoader = null;
}

/// Loads `.html` Trellis templates from a directory into memory at startup.
///
/// Templates are read once and stored as source strings. The backing [Trellis]
/// engine uses a [MapLoader] for DOM caching. All rendering is synchronous —
/// callers use [source] to get the raw template string, then call
/// `trellis.render()` / `trellis.renderFragment()` directly.
///
/// In [devMode], templates are re-read from disk on each [source] call and
/// the Trellis engine watches for file changes to clear its DOM cache.
class TemplateLoaderService {
  final String _basePath;
  final bool devMode;
  final Map<String, String> _sources = {};
  late final Trellis trellis;

  TemplateLoaderService(this._basePath, {this.devMode = false}) {
    for (final name in expectedTemplates) {
      final file = File('$_basePath/$name.html');
      if (file.existsSync()) {
        _sources[name] = file.readAsStringSync();
      }
    }
    if (devMode) {
      trellis = Trellis(loader: FileSystemLoader(_basePath, devMode: true), devMode: true);
    } else {
      trellis = Trellis(loader: MapLoader(_sources));
    }
  }

  /// Returns the raw source string for a named template.
  ///
  /// In dev mode, re-reads from disk so edits take effect immediately.
  /// Throws [StateError] if the template was not loaded at init time.
  String source(String name) {
    if (devMode) {
      final file = File('$_basePath/$name.html');
      if (file.existsSync()) {
        final content = file.readAsStringSync();
        _sources[name] = content;
        return content;
      }
    }
    final s = _sources[name];
    if (s == null) {
      throw StateError('Template "$name" not loaded — was it in expectedTemplates?');
    }
    return s;
  }

  /// Validates that all expected template files exist, are non-empty, and
  /// parse without errors.
  ///
  /// Smoke-renders each template with an empty context to catch syntax
  /// errors at startup (Trellis 0.2.1+ handles null `tl:each` gracefully).
  /// Throws [StateError] with a descriptive message listing all issues.
  void validate() {
    final missing = <String>[];
    final errors = <String, String>{};

    for (final name in expectedTemplates) {
      final file = File('$_basePath/$name.html');
      if (!file.existsSync()) {
        missing.add('$name.html');
        continue;
      }
      final content = _sources[name];
      if (content == null || content.trim().isEmpty) {
        errors[name] = 'Template file is empty';
        continue;
      }
      try {
        trellis.render(content, {});
      } catch (e) {
        errors[name] = 'Smoke render failed: $e';
      }
    }

    if (missing.isNotEmpty || errors.isNotEmpty) {
      final buffer = StringBuffer('Template validation failed:\n');
      if (missing.isNotEmpty) {
        buffer.writeln('  Missing templates: ${missing.join(', ')}');
      }
      for (final entry in errors.entries) {
        buffer.writeln('  Error in ${entry.key}.html: ${entry.value}');
      }
      throw StateError(buffer.toString().trimRight());
    }
  }
}

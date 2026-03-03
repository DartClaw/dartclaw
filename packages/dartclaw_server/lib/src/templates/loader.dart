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
];

TemplateLoader? _templateLoader;

/// Global template loader, initialized at startup via [initTemplates].
///
/// Reads all `.html` template files once at init, then serves them as
/// in-memory source strings for synchronous Trellis rendering.
/// Throws [StateError] if accessed before [initTemplates] is called.
TemplateLoader get templateLoader {
  final loader = _templateLoader;
  if (loader == null) {
    throw StateError('templateLoader not initialized — call initTemplates() first');
  }
  return loader;
}

/// Initializes the global [templateLoader] from `.html` files in [basePath].
///
/// Must be called once before any template rendering (typically in
/// `ServeCommand.run`). Throws [StateError] on missing or empty templates.
void initTemplates(String basePath) {
  _templateLoader = TemplateLoader(basePath);
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
class TemplateLoader {
  final String _basePath;
  final Map<String, String> _sources = {};
  late final Trellis trellis;

  TemplateLoader(this._basePath) {
    for (final name in expectedTemplates) {
      final file = File('$_basePath/$name.html');
      if (file.existsSync()) {
        _sources[name] = file.readAsStringSync();
      }
    }
    trellis = Trellis(loader: MapLoader(_sources));
  }

  /// Returns the raw source string for a named template.
  ///
  /// Throws [StateError] if the template was not loaded at init time.
  String source(String name) {
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

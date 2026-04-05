import 'package:logging/logging.dart';

import 'workflow_context.dart';

/// Resolves `{{variable}}` and `{{context.key}}` placeholders in templates.
///
/// Simple substitution only — no Handlebars conditionals.
class WorkflowTemplateEngine {
  static final _log = Logger('WorkflowTemplateEngine');
  static final _pattern = RegExp(r'\{\{([^}]+)\}\}');

  /// Resolves all template references in [template] against [context].
  ///
  /// - `{{VARIABLE}}` resolves against workflow variables
  /// - `{{context.KEY}}` resolves against accumulated context data
  /// - Missing variables throw [ArgumentError] (fail-fast at start time)
  /// - Missing context keys resolve to empty string with a log warning
  String resolve(String template, WorkflowContext context) {
    return template.replaceAllMapped(_pattern, (match) {
      final ref = match.group(1)!.trim();
      if (ref.startsWith('context.')) {
        final key = ref.substring('context.'.length);
        final value = context[key];
        if (value == null) {
          _log.warning(
            'Template reference {{$ref}} resolved to empty string '
            '(key "$key" not in context)',
          );
          return '';
        }
        return value.toString();
      }
      final value = context.variable(ref);
      if (value == null) {
        throw ArgumentError('Template references undefined variable: {{$ref}}');
      }
      return value;
    });
  }

  /// Extracts all variable references (non-context) from [template].
  ///
  /// Used by validation to check that all referenced variables are declared.
  Set<String> extractVariableReferences(String template) {
    return _pattern
        .allMatches(template)
        .map((m) => m.group(1)!.trim())
        .where((ref) => !ref.startsWith('context.'))
        .toSet();
  }

  /// Extracts all context key references from [template].
  Set<String> extractContextReferences(String template) {
    return _pattern
        .allMatches(template)
        .map((m) => m.group(1)!.trim())
        .where((ref) => ref.startsWith('context.'))
        .map((ref) => ref.substring('context.'.length))
        .toSet();
  }
}

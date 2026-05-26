import '../templates/helpers.dart';

/// Summarizes a tool-call's [input] map into a short display string for activity feeds.
String? summarizeToolInput(String toolName, Map<String, dynamic> input, {int maxLength = 80}) {
  if (input.isEmpty) {
    return null;
  }

  final normalizedTool = toolName.toLowerCase();

  String? formatValue(Object? value) {
    if (value is String) {
      final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (normalized.isNotEmpty) {
        return truncate(normalized, maxLength);
      }
      return null;
    }
    if (value is List) {
      final strings = value.whereType<String>().map((item) => item.trim()).where((item) => item.isNotEmpty).toList();
      if (strings.isEmpty) {
        return null;
      }
      if (strings.length == 1) {
        return truncate(strings.first, maxLength);
      }
      return truncate('${strings.first} (+${strings.length - 1} more)', maxLength);
    }
    return null;
  }

  if (normalizedTool == 'bash' || normalizedTool == 'shell') {
    return formatValue(input['command']) ?? formatValue(input['cmd']);
  }

  if (normalizedTool == 'read' || normalizedTool == 'edit' || normalizedTool == 'write') {
    return formatValue(input['file_path']) ??
        formatValue(input['path']) ??
        formatValue(input['paths']) ??
        formatValue(input['target_file']);
  }

  if (normalizedTool == 'grep' || normalizedTool == 'search') {
    final pattern = formatValue(input['pattern']) ?? formatValue(input['query']) ?? formatValue(input['text']);
    final scope = formatValue(input['path']) ?? formatValue(input['file_path']);
    if (pattern != null && scope != null) {
      return truncate('$pattern in $scope', maxLength);
    }
    return pattern ?? scope;
  }

  if (normalizedTool == 'glob') {
    return formatValue(input['pattern']) ?? formatValue(input['path']) ?? formatValue(input['paths']);
  }

  if (normalizedTool == 'lsp') {
    return formatValue(input['symbol']) ??
        formatValue(input['query']) ??
        formatValue(input['file_path']) ??
        formatValue(input['path']);
  }

  return formatValue(input['path']) ??
      formatValue(input['file_path']) ??
      formatValue(input['command']) ??
      formatValue(input['cmd']) ??
      formatValue(input['pattern']) ??
      formatValue(input['query']) ??
      formatValue(input['text']) ??
      formatValue(input['paths']);
}

/// Formats a tool name and [context] into a present-tense activity description.
String formatToolActivity(String toolName, {String? context, int maxLength = 100}) {
  if (toolName.isEmpty) {
    return '';
  }

  final verb = switch (toolName) {
    'Read' || 'read' => 'Reading',
    'Edit' || 'edit' => 'Editing',
    'Write' || 'write' => 'Writing',
    'Bash' || 'bash' || 'Shell' || 'shell' => 'Running',
    'Grep' || 'grep' || 'Search' || 'search' => 'Searching',
    'Glob' || 'glob' => 'Finding files',
    'LSP' || 'lsp' => 'Analyzing',
    _ => toolName,
  };

  if (context == null || context.isEmpty) {
    return verb;
  }

  return truncate('$verb $context', maxLength);
}

/// Formats a tool name and [context] into a compact event-feed label.
String formatToolEventText(String toolName, {String? context, int maxLength = 80}) {
  if (toolName.isEmpty) {
    return '(tool)';
  }

  if (context == null || context.isEmpty) {
    return truncate(toolName, maxLength);
  }

  return truncate('$toolName $context', maxLength);
}

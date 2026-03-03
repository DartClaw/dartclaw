/// Extracts the text string from an MCP-style result map
/// (`{'content': [{'type': 'text', 'text': '...'}]}`).
String extractMcpText(Map<String, dynamic> result) {
  final content = result['content'] as List?;
  if (content != null && content.isNotEmpty) {
    final first = content[0] as Map<String, dynamic>;
    return first['text'] as String? ?? '';
  }
  return '';
}

/// Filters sensitive data from log output using configurable regex patterns.
class LogRedactor {
  static const _defaultPatterns = [
    r'sk-ant-[a-zA-Z0-9_-]+', // Anthropic API keys
    r'[a-f0-9]{64}', // Gateway tokens (hex)
    r'Bearer [a-zA-Z0-9_.-]+', // Bearer tokens
  ];

  final List<RegExp> _patterns;

  LogRedactor({List<String> patterns = const []}) : _patterns = [
    ..._defaultPatterns.map(RegExp.new),
    ...patterns.map(RegExp.new),
  ];

  String redact(String input) {
    var result = input;
    for (final pattern in _patterns) {
      result = result.replaceAll(pattern, '[REDACTED]');
    }
    return result;
  }
}

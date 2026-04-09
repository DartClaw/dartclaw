import 'package:logging/logging.dart';

import 'guard.dart';
import 'guard_verdict.dart';

// ---------------------------------------------------------------------------
// InputSanitizerConfig
// ---------------------------------------------------------------------------

/// Configuration for the input sanitizer guard — prompt injection pattern lists.
class InputSanitizerConfig {
  /// Whether the guard runs at all.
  final bool enabled;

  /// Whether only channel-originated messages should be scanned.
  final bool channelsOnly;

  /// Compiled regex patterns grouped by high-level injection category.
  final List<({String category, RegExp pattern})> patterns;

  /// Creates an input sanitizer configuration from precompiled patterns.
  InputSanitizerConfig({required this.enabled, required this.channelsOnly, required this.patterns});

  /// Hardcoded safe defaults — ships with built-in patterns for 4 injection categories.
  factory InputSanitizerConfig.defaults() =>
      InputSanitizerConfig(enabled: true, channelsOnly: true, patterns: _defaultPatterns);

  /// Merges extra patterns from YAML config with defaults.
  factory InputSanitizerConfig.fromYaml(Map<String, dynamic> yaml) {
    final defaults = InputSanitizerConfig.defaults();

    final enabled = yaml['enabled'];
    final channelsOnly = yaml['channels_only'];

    // Extra patterns (regex strings)
    final extraPatterns = <({String category, RegExp pattern})>[];
    final rawExtra = yaml['extra_patterns'];
    if (rawExtra is List) {
      for (final p in rawExtra) {
        if (p is String) {
          try {
            extraPatterns.add((category: 'custom', pattern: RegExp(p, caseSensitive: false)));
          } catch (e) {
            _log.warning('Skipping malformed extra_pattern "$p": $e');
          }
        }
      }
    }

    return InputSanitizerConfig(
      enabled: enabled is bool ? enabled : defaults.enabled,
      channelsOnly: channelsOnly is bool ? channelsOnly : defaults.channelsOnly,
      patterns: [...defaults.patterns, ...extraPatterns],
    );
  }

  static final _log = Logger('InputSanitizerConfig');

  // --- Default patterns (4 categories from PRD §F01) ---

  static final _defaultPatterns = <({String category, RegExp pattern})>[
    // Instruction override
    ..._category('instruction override', [
      r'ignore\s+(all\s+)?previous',
      r'disregard\s+(all\s+)?(above|previous)',
      r'forget\s+(your\s+)?instructions',
      r'you\s+are\s+now',
      r'new\s+role\s*:',
      r'^system\s*:',
    ]),
    // Role-play
    ..._category('role-play', [r'pretend\s+(you\s+are|to\s+be)', r'act\s+as\s+if', r'roleplay\s+as']),
    // Prompt leak
    ..._category('prompt leak', [
      r'repeat\s+your\s+(system\s+)?prompt',
      r'show\s+me\s+your\s+instructions',
      r'what\s+are\s+your\s+rules',
    ]),
    // Meta-injection
    ..._category('meta-injection', [r'\[INST\]', r'<\|im_start\|>', r'<\/?s>', r'<system>', r'<tool_result>']),
  ];

  static List<({String category, RegExp pattern})> _category(String name, List<String> regexes) {
    return regexes.map((r) => (category: name, pattern: RegExp(r, caseSensitive: false))).toList();
  }
}

// ---------------------------------------------------------------------------
// InputSanitizer
// ---------------------------------------------------------------------------

/// Regex-based prompt injection blocking guard.
///
/// Scans inbound messages for prompt injection patterns on the
/// `messageReceived` hook. Ships with built-in patterns for 4 injection
/// categories. Channels-only by default (web UI messages bypass).
class InputSanitizer extends Guard {
  static final _log = Logger('InputSanitizer');

  @override
  String get name => 'input-sanitizer';

  @override
  String get category => 'input';

  /// Pattern configuration used for prompt-injection scanning.
  InputSanitizerConfig config;

  /// Creates an input sanitizer with defaults unless overridden.
  InputSanitizer({InputSanitizerConfig? config}) : config = config ?? InputSanitizerConfig.defaults();

  /// Rebuilds config from new YAML. Called by the reconfigurability adapter in wiring.
  void reconfigureFromYaml(Map<String, dynamic>? guardsYaml) {
    final yaml = guardsYaml?['input_sanitizer'];
    if (yaml is Map) {
      config = InputSanitizerConfig.fromYaml(Map<String, dynamic>.from(yaml));
    } else {
      config = InputSanitizerConfig.defaults();
    }
    _log.info('InputSanitizer reconfigured (${config.patterns.length} patterns, enabled: ${config.enabled})');
  }

  /// Maximum content length scanned per message. Content beyond this limit is
  /// truncated before matching to bound worst-case regex backtracking time.
  /// The GuardChain enforces a 5-second wall-clock timeout on the full guard
  /// evaluation, which acts as the outer safety net.
  static const _maxScanChars = 10000;

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    if (!config.enabled) return GuardVerdict.pass();
    if (context.hookPoint != 'messageReceived') return GuardVerdict.pass();
    if (config.channelsOnly && context.source != 'channel') {
      return GuardVerdict.pass();
    }

    final raw = context.messageContent;
    if (raw == null || raw.isEmpty) return GuardVerdict.pass();

    // Truncate oversized content to bound quadratic regex backtracking.
    final content = raw.length > _maxScanChars ? raw.substring(0, _maxScanChars) : raw;

    for (final entry in config.patterns) {
      try {
        if (entry.pattern.hasMatch(content)) {
          return GuardVerdict.block('Prompt injection detected: ${entry.category}');
        }
      } catch (e) {
        // Pattern error — skip this pattern (fail-open per pattern, not per guard)
        Logger('InputSanitizer').warning('Pattern match error: $e');
      }
    }

    return GuardVerdict.pass();
  }
}

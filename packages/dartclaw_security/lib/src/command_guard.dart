import 'guard.dart';
import 'guard_verdict.dart';

// ---------------------------------------------------------------------------
// CommandGuardConfig
// ---------------------------------------------------------------------------

/// Configuration for the command guard — pattern lists for dangerous commands.
class CommandGuardConfig {
  /// Regexes that match destructive shell commands such as `rm -rf`.
  final List<RegExp> destructivePatterns;

  /// Regexes that match forceful operations such as `git push --force`.
  final List<RegExp> forcePatterns;

  /// Regexes that match known fork-bomb constructs.
  final List<RegExp> forkBombPatterns;

  /// Regexes that match interpreter escape patterns.
  final List<RegExp> interpreterEscapes;

  /// Command names that are blocked when used as pipe targets.
  final Set<String> blockedPipeTargets;

  /// Pipe targets explicitly treated as safe text-processing tools.
  final Set<String> safePipeTargets;

  /// Creates a command guard configuration from precompiled rules.
  CommandGuardConfig({
    required this.destructivePatterns,
    required this.forcePatterns,
    required this.forkBombPatterns,
    required this.interpreterEscapes,
    required this.blockedPipeTargets,
    required this.safePipeTargets,
  });

  /// Hardcoded safe defaults — used when config is missing or malformed.
  factory CommandGuardConfig.defaults() => CommandGuardConfig(
    destructivePatterns: _defaultDestructive,
    forcePatterns: _defaultForce,
    forkBombPatterns: _defaultForkBombs,
    interpreterEscapes: _defaultInterpreterEscapes,
    blockedPipeTargets: _defaultBlockedPipeTargets,
    safePipeTargets: _defaultSafePipeTargets,
  );

  /// Merges extra patterns from YAML config with defaults.
  factory CommandGuardConfig.fromYaml(Map<String, dynamic> yaml) {
    final defaults = CommandGuardConfig.defaults();

    // Extra blocked patterns (regex strings)
    final extraPatterns = <RegExp>[];
    final rawExtra = yaml['extra_blocked_patterns'];
    if (rawExtra is List) {
      for (final p in rawExtra) {
        if (p is String) {
          try {
            extraPatterns.add(RegExp(p));
          } catch (_) {
            // Skip malformed regex
          }
        }
      }
    }

    // Extra blocked pipe targets
    final extraPipeTargets = <String>{};
    final rawPipe = yaml['extra_blocked_pipe_targets'];
    if (rawPipe is List) {
      for (final t in rawPipe) {
        if (t is String) extraPipeTargets.add(t);
      }
    }

    return CommandGuardConfig(
      destructivePatterns: [...defaults.destructivePatterns, ...extraPatterns],
      forcePatterns: defaults.forcePatterns,
      forkBombPatterns: defaults.forkBombPatterns,
      interpreterEscapes: defaults.interpreterEscapes,
      blockedPipeTargets: {...defaults.blockedPipeTargets, ...extraPipeTargets},
      safePipeTargets: defaults.safePipeTargets,
    );
  }

  // --- Default patterns ---

  static final _defaultDestructive = [
    // Combined flags (-rf, -fr) or space-separated (-r -f, -f -r)
    RegExp(
      r'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r|--no-preserve-root|-[a-zA-Z]*r\s+-[a-zA-Z]*f|-[a-zA-Z]*f\s+-[a-zA-Z]*r)',
    ),
    RegExp(r'chmod\s+(777|000|a\+rwx)'),
    RegExp(r'mkfs\.'),
    RegExp(r'dd\s+if='),
    RegExp(r'>\s*/dev/sd'),
  ];

  static final _defaultForce = [
    RegExp(r'git\s+push\s+.*--force'),
    RegExp(r'git\s+push\s+.*-f\b'),
    RegExp(r'git\s+reset\s+--hard'),
    RegExp(r'git\s+clean\s+-[a-zA-Z]*f'),
  ];

  static final _defaultForkBombs = [RegExp(r':\(\)\s*\{'), RegExp(r'\|\s*:\s*&')];

  static final _defaultInterpreterEscapes = [
    RegExp(r'\beval\s+'),
    RegExp(r'\bbash\s+(-[a-zA-Z]*c|-c)\b'),
    RegExp(r'\bsh\s+(-[a-zA-Z]*c|-c)\b'),
    RegExp(r'\bzsh\s+(-[a-zA-Z]*c|-c)\b'),
    RegExp(r'\bdash\s+(-[a-zA-Z]*c|-c)\b'),
    RegExp(r'\bpython[23]?\s+-c\b'),
    RegExp(r'\bnode\s+-e\b'),
    RegExp(r'\bperl\s+-e\b'),
    RegExp(r'\bruby\s+-e\b'),
    // Backtick subshell execution — executes arbitrary commands inline.
    // Note: $(...) subshells are not blocked here because the inner command
    // is still scanned by destructive/force/forkBomb patterns above. Variable
    // expansion bypasses (e.g. v=rm; $v -rf) cannot be caught statically and
    // require container isolation as the primary security boundary.
    RegExp(r'`[^`]+`'),
    // xargs piping to interpreters — bypasses both pipe target and -c checks
    RegExp(r'\bxargs\s+(sh|bash|zsh|dash|python[23]?|perl|ruby|node)\b'),
  ];

  static const _defaultBlockedPipeTargets = {
    'sh', 'bash', 'zsh', 'dash',
    'python', 'python3', 'perl', 'ruby', 'node',
    'sed', // sed 'e' flag can execute shell commands on piped input
  };

  static const _defaultSafePipeTargets = {
    'jq',
    'grep',
    'sort',
    'wc',
    'head',
    'tail',
    'cat',
    'less',
    'tee',
    'uniq',
    'tr',
    'cut',
    'awk',
    'fmt',
    'column',
  };
}

// ---------------------------------------------------------------------------
// CommandGuard
// ---------------------------------------------------------------------------

/// Regex-based dangerous command blocking guard.
///
/// Only evaluates on `beforeToolCall` for the `Bash` tool.
/// Strips single-quoted strings, extracts pipe segments, and matches
/// against configurable regex patterns.
class CommandGuard extends Guard {
  @override
  String get name => 'command';

  @override
  String get category => 'command';

  /// Active rule set used when scanning shell commands.
  final CommandGuardConfig config;

  /// Creates a command guard with defaults unless overridden.
  CommandGuard({CommandGuardConfig? config}) : config = config ?? CommandGuardConfig.defaults();

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    if (context.hookPoint != 'beforeToolCall' || context.toolName != 'Bash') {
      return GuardVerdict.pass();
    }

    final command = context.toolInput?['command'];
    if (command is! String || command.isEmpty) {
      return GuardVerdict.pass();
    }

    final raw = _normalizeQuotedShellWords(command);
    final processed = _stripSingleQuotes(command);
    final reasons = <String>{};

    _matchCategory(command, config.interpreterEscapes, 'interpreter escape', reasons);
    _matchCategory(raw, config.destructivePatterns, 'destructive command', reasons);
    _matchCategory(raw, config.forcePatterns, 'force operation', reasons);
    _matchCategory(raw, config.forkBombPatterns, 'fork bomb', reasons);
    _matchCategory(raw, config.interpreterEscapes, 'interpreter escape', reasons);
    _matchCategory(processed, config.destructivePatterns, 'destructive command', reasons);
    _matchCategory(processed, config.forcePatterns, 'force operation', reasons);
    _matchCategory(processed, config.forkBombPatterns, 'fork bomb', reasons);
    _matchCategory(processed, config.interpreterEscapes, 'interpreter escape', reasons);

    _collectPipeTargetReasons(command, reasons);
    _collectPipeTargetReasons(raw, reasons);
    _collectPipeTargetReasons(processed, reasons);

    if (reasons.isNotEmpty) {
      return GuardVerdict.block('Command blocked: ${reasons.join(', ')}');
    }

    return GuardVerdict.pass();
  }

  /// Removes whole single-quoted regions when looking for unsafe patterns.
  ///
  /// Known limitations: double quotes, heredocs, and variable expansion are not
  /// interpreted here. Container isolation remains the primary security
  /// boundary for shell execution.
  static String _stripSingleQuotes(String cmd) {
    return cmd.replaceAll(RegExp(r"'[^']*'"), '');
  }

  /// Removes quote characters around single shell words while preserving
  /// only the structural information from quoted multi-word literals.
  static String _normalizeQuotedShellWords(String cmd) {
    return cmd.replaceAllMapped(RegExp(r"'([^']*)'"), (match) {
      final content = match.group(1)!;
      return content.contains(RegExp(r'\s')) ? '' : content;
    });
  }

  /// Splits command on pipe operator `|`, excluding `||` (logical OR).
  static List<String> _extractPipeSegments(String cmd) {
    return cmd.split(RegExp(r'(?<!\|)\|(?!\|)'));
  }

  void _collectPipeTargetReasons(String cmd, Set<String> reasons) {
    final pipeSegments = _extractPipeSegments(cmd);
    if (pipeSegments.length <= 1) return;

    for (var i = 1; i < pipeSegments.length; i++) {
      final target = _pipeTarget(pipeSegments[i]);
      if (config.blockedPipeTargets.contains(target)) {
        reasons.add('blocked pipe target: $target');
      }
    }
  }

  static String _pipeTarget(String segment) {
    final trimmed = segment.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    if (trimmed.startsWith("'")) {
      final closingQuote = trimmed.indexOf("'", 1);
      if (closingQuote > 1) {
        return trimmed.substring(1, closingQuote).split(RegExp(r'\s+')).first;
      }
    }

    return trimmed.split(RegExp(r'\s+')).first;
  }

  static void _matchCategory(String cmd, List<RegExp> patterns, String label, Set<String> reasons) {
    for (final pattern in patterns) {
      if (pattern.hasMatch(cmd)) {
        reasons.add(label);
        return; // One match per category is sufficient
      }
    }
  }
}

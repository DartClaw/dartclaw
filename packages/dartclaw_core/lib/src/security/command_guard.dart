import 'guard.dart';
import 'guard_verdict.dart';

// ---------------------------------------------------------------------------
// CommandGuardConfig
// ---------------------------------------------------------------------------

/// Configuration for the command guard — pattern lists for dangerous commands.
class CommandGuardConfig {
  final List<RegExp> destructivePatterns;
  final List<RegExp> forcePatterns;
  final List<RegExp> forkBombPatterns;
  final List<RegExp> interpreterEscapes;
  final Set<String> blockedPipeTargets;
  final Set<String> safePipeTargets;

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
    RegExp(r'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r|--no-preserve-root|-[a-zA-Z]*r\s+-[a-zA-Z]*f|-[a-zA-Z]*f\s+-[a-zA-Z]*r)'),
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

  static final _defaultForkBombs = [
    RegExp(r':\(\)\s*\{'),
    RegExp(r'\|\s*:\s*&'),
  ];

  static final _defaultInterpreterEscapes = [
    RegExp(r'\beval\s+'),
    RegExp(r'\bbash\s+-c\b'),
    RegExp(r'\bsh\s+-c\b'),
    RegExp(r'\bzsh\s+-c\b'),
    RegExp(r'\bdash\s+-c\b'),
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
    'jq', 'grep', 'sort', 'wc', 'head', 'tail',
    'cat', 'less', 'tee', 'uniq', 'tr', 'cut',
    'awk', 'fmt', 'column',
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

  final CommandGuardConfig config;

  CommandGuard({CommandGuardConfig? config})
      : config = config ?? CommandGuardConfig.defaults();

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    if (context.hookPoint != 'beforeToolCall' || context.toolName != 'Bash') {
      return GuardVerdict.pass();
    }

    final command = context.toolInput?['command'];
    if (command is! String || command.isEmpty) {
      return GuardVerdict.pass();
    }

    final processed = _stripSingleQuotes(command);
    final reasons = <String>[];

    // Check all pattern categories
    _matchCategory(processed, config.destructivePatterns, 'destructive command', reasons);
    _matchCategory(processed, config.forcePatterns, 'force operation', reasons);
    _matchCategory(processed, config.forkBombPatterns, 'fork bomb', reasons);
    _matchCategory(processed, config.interpreterEscapes, 'interpreter escape', reasons);

    // Check pipe targets
    final pipeSegments = _extractPipeSegments(processed);
    if (pipeSegments.length > 1) {
      for (var i = 1; i < pipeSegments.length; i++) {
        final target = pipeSegments[i].trim().split(RegExp(r'\s+')).first;
        if (config.blockedPipeTargets.contains(target)) {
          reasons.add('blocked pipe target: $target');
        }
      }
    }

    if (reasons.isNotEmpty) {
      return GuardVerdict.block('Command blocked: ${reasons.join(', ')}');
    }

    return GuardVerdict.pass();
  }

  /// Strips content inside single quotes to prevent bypass via `'rm' '-rf'`.
  static String _stripSingleQuotes(String cmd) {
    return cmd.replaceAll(RegExp(r"'[^']*'"), '');
  }

  /// Splits command on pipe operator `|`, excluding `||` (logical OR).
  static List<String> _extractPipeSegments(String cmd) {
    return cmd.split(RegExp(r'(?<!\|)\|(?!\|)'));
  }

  static void _matchCategory(
    String cmd,
    List<RegExp> patterns,
    String label,
    List<String> reasons,
  ) {
    for (final pattern in patterns) {
      if (pattern.hasMatch(cmd)) {
        reasons.add(label);
        return; // One match per category is sufficient
      }
    }
  }
}

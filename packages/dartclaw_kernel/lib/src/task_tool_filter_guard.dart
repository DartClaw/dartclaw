import 'command_vocabulary.dart';
import 'guard.dart';
import 'guard_verdict.dart';

/// Guard that restricts tool usage to a task-specific allowlist.
///
/// When [allowedTools] is null or empty, all tools are permitted.
/// When set, any capability not in the list is blocked. Claude's exact
/// schema-discovery helper may pass; the selected capability remains filtered.
class TaskToolFilterGuard extends Guard {
  static const _noToolsPolicy = '__knowledge_inbox_no_tools__';

  @override
  String get name => 'task_tool_filter';

  @override
  String get category => 'tool';

  /// Mutable allowlist — set before each turn via [TaskExecutor].
  /// Null/empty means unrestricted.
  List<String>? allowedTools;

  /// When true, blocks mutating file tools and every shell command that is not
  /// proven read-only.
  ///
  /// This is intended for workflow steps that must remain read-only even when
  /// they still need shell access for discovery commands such as `find`,
  /// `test`, `pwd`, or `git status`. Shell admission is an allowlist, so an
  /// unrecognized binary blocks.
  bool readOnly = false;

  final Map<String, List<String>?> _allowedToolsBySession = {};
  final Set<String> _readOnlySessionIds = {};

  /// Sets a session-local tool allowlist that overrides [allowedTools].
  ///
  /// Passing null clears the session override. The policy applies only when the
  /// guard context carries the same session ID.
  void setSessionToolFilter(String sessionId, List<String>? allowedTools) {
    if (allowedTools == null) {
      _allowedToolsBySession.remove(sessionId);
      return;
    }
    _allowedToolsBySession[sessionId] = List.unmodifiable(allowedTools);
  }

  /// Enables or disables read-only enforcement for one session.
  ///
  /// Session read-only mode is additive with [readOnly]; a globally read-only
  /// guard still blocks mutating tools for every session.
  void setSessionReadOnly(String sessionId, bool readOnly) {
    if (readOnly) {
      _readOnlySessionIds.add(sessionId);
    } else {
      _readOnlySessionIds.remove(sessionId);
    }
  }

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    if (context.hookPoint != 'beforeToolCall') return GuardVerdict.pass();

    final sessionId = context.sessionId;
    final sessionReadOnly = sessionId != null && _readOnlySessionIds.contains(sessionId);
    final readOnlyVerdict = _evaluateReadOnly(context, readOnly || sessionReadOnly);
    if (readOnlyVerdict != null) return readOnlyVerdict;

    final hasSessionPolicy = sessionId != null && _allowedToolsBySession.containsKey(sessionId);
    final tools = hasSessionPolicy ? _allowedToolsBySession[sessionId] : allowedTools;
    if (tools == null || tools.isEmpty) return GuardVerdict.pass();
    if (tools.contains(_noToolsPolicy)) {
      return GuardVerdict.block(
        'Tool "${context.toolName ?? 'unknown'}" is not in this task\'s allowed tools: ${tools.join(', ')}',
      );
    }
    final toolName = context.toolName;
    if (toolName == null) return GuardVerdict.pass();
    if (tools.contains(toolName)) return GuardVerdict.pass();
    // Discovery exposes schemas only; the selected tool is evaluated separately.
    if (toolName == 'claude:ToolSearch' && context.rawProviderToolName == 'ToolSearch') {
      return GuardVerdict.pass();
    }
    return GuardVerdict.block('Tool "$toolName" is not in this task\'s allowed tools: ${tools.join(', ')}');
  }

  GuardVerdict? _evaluateReadOnly(GuardContext context, bool readOnlyActive) {
    if (!readOnlyActive) return null;

    final toolName = context.toolName;
    final toolInput = context.toolInput;
    if (toolName == null) return null;

    if (toolName == 'file_write' || toolName == 'file_edit') {
      return GuardVerdict.block('Tool "$toolName" is not allowed while this task is read-only');
    }

    if (toolName == 'memory_apply' || toolName == 'memory_observe') {
      return GuardVerdict.block('Tool "$toolName" is not allowed while this task is read-only');
    }

    if (toolName != 'shell') return null;
    final command = toolInput?['command'];
    // A shell call whose command this guard cannot read is not a command it can
    // prove read-only, so it blocks rather than falling through to the
    // tool-allowlist path.
    if (command is! String || command.trim().isEmpty) {
      return GuardVerdict.block('Shell command is not readable while this task is read-only');
    }
    if (!_shellIsReadOnly(command)) {
      return GuardVerdict.block(
        'Shell command is not allowed while this task is read-only: '
        'only commands proven read-only are permitted',
      );
    }
    return null;
  }

  static final _envAssignmentPrefix = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=');
  // `git log -20` is the shorthand for `--max-count=20`; no other subcommand
  // reads a bare number as a flag.
  static final _gitLogCountFlag = RegExp(r'^-\d+$');
  static const _mutatingFindActions = {
    '-delete',
    '-exec',
    '-execdir',
    '-ok',
    '-okdir',
    '-fprint',
    '-fprint0',
    '-fprintf',
    '-fls',
  };

  /// Whether every segment of [command] resolves to an allowlisted read-only
  /// binary.
  ///
  /// Fail-closed: a redirect, a command substitution, an env-var assignment
  /// prefix, `sudo`, an unterminated quote, or any binary outside
  /// `readOnlyShellCommands` makes the whole command not read-only.
  static bool _shellIsReadOnly(String command) {
    final segments = _tokenize(command);
    if (segments == null || segments.isEmpty) return false;
    for (final tokens in segments) {
      if (!_segmentIsReadOnly(tokens)) return false;
    }
    return true;
  }

  /// Splits [command] into segments of quote-stripped tokens.
  ///
  /// Returns null for any shape this parser cannot account for — a redirect,
  /// a command substitution, or an unterminated quote or escape. Quoting is
  /// resolved the way a shell resolves it, so an operator inside quotes is
  /// argument text (`grep 'a|b'` is one command) while an escaped quote cannot
  /// hide one (`echo \" > f \"` is a redirect).
  static List<List<String>>? _tokenize(String command) {
    final segments = <List<String>>[];
    var tokens = <String>[];
    final buffer = StringBuffer();
    var hasToken = false;

    void endToken() {
      if (!hasToken) return;
      tokens.add(buffer.toString());
      buffer.clear();
      hasToken = false;
    }

    void endSegment() {
      endToken();
      if (tokens.isEmpty) return;
      segments.add(tokens);
      tokens = <String>[];
    }

    for (var i = 0; i < command.length; i++) {
      final c = command[i];
      if (c == r'\') {
        if (i + 1 >= command.length) return null;
        buffer.write(command[i + 1]);
        hasToken = true;
        i++;
        continue;
      }
      if (c == "'") {
        final close = command.indexOf("'", i + 1);
        if (close < 0) return null;
        buffer.write(command.substring(i + 1, close));
        hasToken = true;
        i = close;
        continue;
      }
      if (c == '"') {
        var j = i + 1;
        while (j < command.length && command[j] != '"') {
          if (command[j] == r'\' && j + 1 < command.length) {
            buffer.write(command[j + 1]);
            j += 2;
            continue;
          }
          // Substitution still runs inside double quotes.
          if (command[j] == '`') return null;
          if (command[j] == r'$' && j + 1 < command.length && command[j + 1] == '(') return null;
          buffer.write(command[j]);
          j++;
        }
        if (j >= command.length) return null;
        hasToken = true;
        i = j;
        continue;
      }
      if (c == '`') return null;
      if (c == r'$' && i + 1 < command.length && command[i + 1] == '(') return null;
      // Redirects and process substitution.
      if (c == '>' || c == '<') return null;
      if (c == '&' || c == '|' || c == ';' || c == '\n' || c == '\r') {
        if (i + 1 < command.length && command[i + 1] == c) i++;
        endSegment();
        continue;
      }
      if (c == ' ' || c == '\t') {
        endToken();
        continue;
      }
      buffer.write(c);
      hasToken = true;
    }
    endSegment();
    return segments;
  }

  static bool _segmentIsReadOnly(List<String> tokens) {
    if (tokens.isEmpty) return false;

    final cmd = tokens.first;
    if (_envAssignmentPrefix.hasMatch(cmd)) return false;
    if (cmd == 'sudo') return false;

    final args = tokens.skip(1).toList(growable: false);

    if (cmd == 'git') return _gitIsReadOnly(args);
    // `find` reads unless it carries an action that writes or executes.
    if (cmd == 'find') return !args.any(_mutatingFindActions.contains);

    return readOnlyShellCommands.contains(cmd);
  }

  /// Whether `git` with [args] is admitted by [readOnlyGitCommands].
  ///
  /// Fail-closed in three places: the subcommand must be the first argument, so
  /// a pre-subcommand global such as `--exec-path=…` (which points git at
  /// another program directory) is rejected before anything else is read; an
  /// unlisted subcommand blocks; and an unlisted flag blocks, which is what
  /// keeps `--help`, `-h`, `--edit-description` and the `--set-upstream-to=…`
  /// family out. A flag written `--name=value` is judged on `--name`, while a
  /// short flag is matched whole, so an attached value (`-uorigin/main`) cannot
  /// pass as its bare form.
  static bool _gitIsReadOnly(List<String> args) {
    if (args.isEmpty) return false;
    final subcommand = args.first;
    if (subcommand.startsWith('-')) return false;
    final policy = readOnlyGitCommands[subcommand];
    if (policy == null) return false;

    var positionals = 0;
    var sawPathspecSeparator = false;
    for (final arg in args.skip(1)) {
      // git reads everything after `--` as a path or a ref, including a token
      // shaped like a flag, so the budget must count them.
      if (arg == '--') {
        sawPathspecSeparator = true;
        continue;
      }
      if (!sawPathspecSeparator && arg.startsWith('-') && arg != '-') {
        final name = arg.startsWith('--') ? arg.split('=').first : arg;
        if (policy.flags.contains(name)) continue;
        if (subcommand == 'log' && _gitLogCountFlag.hasMatch(arg)) continue;
        return false;
      }
      positionals++;
    }
    final budget = policy.maxPositionals;
    return budget == null || positionals <= budget;
  }
}

import 'guard.dart';
import 'guard_verdict.dart';

/// Guard that restricts tool usage to a task-specific allowlist.
///
/// When [allowedTools] is null or empty, all tools are permitted.
/// When set, any tool not in the list is blocked.
class TaskToolFilterGuard extends Guard {
  @override
  String get name => 'task_tool_filter';

  @override
  String get category => 'tool';

  /// Mutable allowlist — set before each turn via [TaskExecutor].
  /// Null/empty means unrestricted.
  List<String>? allowedTools;

  /// When true, blocks mutating file tools and mutating shell commands.
  ///
  /// This is intended for workflow steps that must remain read-only even when
  /// they still need shell access for discovery commands such as `find`,
  /// `test`, `pwd`, or `git status`.
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
    final toolName = context.toolName;
    if (toolName == null) return GuardVerdict.pass();
    if (tools.contains(toolName)) return GuardVerdict.pass();
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

    if (toolName != 'shell') return null;
    final command = toolInput?['command'];
    if (command is! String || command.trim().isEmpty) return null;
    if (_shellMayMutate(command)) {
      return GuardVerdict.block('Mutating shell commands are not allowed while this task is read-only');
    }
    return null;
  }

  static final _redirectPattern = RegExp(r'(?:>>|>|2>>|2>|&>)\s*(\S+)');
  static const _writeCommands = {
    'tee',
    'touch',
    'chmod',
    'chown',
    'vi',
    'vim',
    'nano',
    'mkdir',
    'mktemp',
    'install',
    'ln',
  };
  static const _deleteCommands = {'rm', 'unlink', 'rmdir'};
  static const _copyMoveCommands = {'cp', 'mv'};
  static const _mutatingGitSubcommands = {
    'add',
    'am',
    'apply',
    'branch',
    'checkout',
    'cherry-pick',
    'clean',
    'clone',
    'commit',
    'fetch',
    'init',
    'merge',
    'mv',
    'pull',
    'push',
    'rebase',
    'reset',
    'restore',
    'revert',
    'rm',
    'stash',
    'switch',
    'tag',
    'worktree',
  };
  static const _readOnlyGitSubcommands = {
    'blame',
    'branch',
    'describe',
    'diff',
    'grep',
    'log',
    'ls-files',
    'remote',
    'rev-parse',
    'show',
    'status',
    'symbolic-ref',
  };

  static bool _shellMayMutate(String command) {
    if (_redirectPattern.hasMatch(command)) return true;

    final subCommands = command.split(RegExp(r'\s*(?:&&|;)\s*'));
    for (final sub in subCommands) {
      final pipeFirst = sub.split(RegExp(r'(?<!\|)\|(?!\|)')).first.trim();
      if (pipeFirst.isEmpty) continue;

      final tokens = pipeFirst.split(RegExp(r'\s+'));
      if (tokens.isEmpty) continue;

      var cmdIdx = 0;
      if (tokens[cmdIdx] == 'sudo' && tokens.length > 1) cmdIdx++;
      final cmd = tokens[cmdIdx];
      final args = tokens.skip(cmdIdx + 1).toList(growable: false);

      if (_writeCommands.contains(cmd) || _deleteCommands.contains(cmd) || _copyMoveCommands.contains(cmd)) {
        return true;
      }
      if (cmd == 'sed' && pipeFirst.contains(RegExp(r'\s-i\b|--in-place'))) {
        return true;
      }
      if (cmd == 'git') {
        final firstArg = args.firstWhere((arg) => !arg.startsWith('-'), orElse: () => '');
        if (firstArg.isEmpty) continue;
        if (_mutatingGitSubcommands.contains(firstArg) && !_readOnlyGitSubcommands.contains(firstArg)) {
          // `git branch` without an explicit branch name is read-only listing.
          if (firstArg == 'branch' && args.where((arg) => !arg.startsWith('-')).length <= 1) {
            continue;
          }
          return true;
        }
      }
    }

    return false;
  }
}

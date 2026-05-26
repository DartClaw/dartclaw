import 'dart:convert';
import 'dart:io';

/// Default env names allowed through to minimal shell-style subprocesses.
const defaultBashStepEnvAllowlist = <String>[
  'PATH',
  'HOME',
  'LANG',
  'LC_*',
  'TZ',
  'USER',
  'SHELL',
  'TERM',
  'TMPDIR',
  'TMP',
  'TEMP',
];

/// Default env names allowed through to git subprocesses.
///
/// `SSH_AUTH_SOCK` is allowlisted so that git+ssh transports can reach the
/// user's running ssh-agent without falling back to interactive passphrase
/// prompts (which `GIT_SSH_COMMAND="ssh -o BatchMode=yes"` rejects anyway).
/// `SSH_AGENT_PID` is the benign companion that ssh libraries sometimes
/// consult; no credentials ever travel through either variable — they only
/// name a Unix socket and a process ID.
const defaultGitEnvAllowlist = <String>[
  'PATH',
  'HOME',
  'LANG',
  'LC_*',
  'TZ',
  'USER',
  'SHELL',
  'TERM',
  'SSH_AUTH_SOCK',
  'SSH_AGENT_PID',
];

/// Default patterns stripped when sanitizing a parent environment.
final List<Pattern> defaultSensitivePatterns = <Pattern>[
  RegExp(r'.*_API_KEY$', caseSensitive: false),
  RegExp(r'.*_SECRET$', caseSensitive: false),
  RegExp(r'.*_TOKEN$', caseSensitive: false),
  RegExp(r'.*_CREDENTIAL$', caseSensitive: false),
  RegExp(r'.*_PASSWORD$', caseSensitive: false),
];

/// Minimal shared interface for env-overlay plans.
abstract interface class ProcessEnvironmentPlan {
  /// Environment entries to overlay onto the sanitized base environment.
  Map<String, String> get environment;
}

/// Selects how a [SafeProcess] spawn resolves the child's environment.
sealed class EnvPolicy {
  const EnvPolicy();

  /// Inherits the parent environment unchanged (or substitutes [environment] if given).
  const factory EnvPolicy.passthrough({Map<String, String>? environment}) = _PassThroughEnvPolicy;

  /// Sanitizes the parent environment via allowlist + sensitive-name strip.
  const factory EnvPolicy.sanitize({
    List<String>? allowlist,
    Map<String, String> extraEnvironment,
    List<Pattern>? sensitivePatterns,
  }) = _SanitizeEnvPolicy;

  /// Sanitizes against the bash-step allowlist; suitable for shell tool steps.
  const factory EnvPolicy.minimal({Map<String, String> extraEnvironment}) = _MinimalEnvPolicy;

  /// Sanitizes against the git allowlist and overlays a credential plan.
  const factory EnvPolicy.credentialPlan({required ProcessEnvironmentPlan plan, bool noSystemConfig}) =
      _CredentialPlanEnvPolicy;
}

final class _PassThroughEnvPolicy extends EnvPolicy {
  final Map<String, String>? environment;

  const _PassThroughEnvPolicy({this.environment});
}

final class _SanitizeEnvPolicy extends EnvPolicy {
  final List<String>? allowlist;
  final Map<String, String> extraEnvironment;
  final List<Pattern>? sensitivePatterns;

  const _SanitizeEnvPolicy({this.allowlist, this.extraEnvironment = const <String, String>{}, this.sensitivePatterns});
}

final class _MinimalEnvPolicy extends EnvPolicy {
  final Map<String, String> extraEnvironment;

  const _MinimalEnvPolicy({this.extraEnvironment = const <String, String>{}});
}

final class _CredentialPlanEnvPolicy extends EnvPolicy {
  final ProcessEnvironmentPlan plan;
  final bool noSystemConfig;

  const _CredentialPlanEnvPolicy({required this.plan, this.noSystemConfig = false});
}

/// Process helper that requires an explicit environment policy for every spawn.
abstract final class SafeProcess {
  /// Returns a sanitized environment map filtered by [allowlist] and sensitive-name [sensitivePatterns].
  static Map<String, String> sanitize({
    Map<String, String>? baseEnvironment,
    List<String>? allowlist,
    Map<String, String> extraEnvironment = const <String, String>{},
    List<Pattern>? sensitivePatterns,
  }) {
    final source = baseEnvironment ?? Platform.environment;
    final effectivePatterns = sensitivePatterns ?? defaultSensitivePatterns;
    final sanitized = <String, String>{};

    for (final entry in source.entries) {
      if (_isSensitive(entry.key, effectivePatterns)) continue;
      if (allowlist != null && !_matchesAllowlist(entry.key, allowlist)) continue;
      sanitized[entry.key] = entry.value;
    }

    sanitized.addAll(extraEnvironment);
    return sanitized;
  }

  /// Runs [executable] under the given [env] policy and returns the [ProcessResult].
  static Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    required EnvPolicy env,
    String? workingDirectory,
    Map<String, String>? baseEnvironment,
    Encoding stdoutEncoding = systemEncoding,
    Encoding stderrEncoding = systemEncoding,
    bool runInShell = false,
  }) {
    return Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: _resolveEnvironment(env, baseEnvironment: baseEnvironment),
      includeParentEnvironment: false,
      stdoutEncoding: stdoutEncoding,
      stderrEncoding: stderrEncoding,
      runInShell: runInShell,
    );
  }

  /// Starts [executable] under the given [env] policy and returns the long-lived [Process].
  static Future<Process> start(
    String executable,
    List<String> arguments, {
    required EnvPolicy env,
    String? workingDirectory,
    Map<String, String>? baseEnvironment,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: _resolveEnvironment(env, baseEnvironment: baseEnvironment),
      includeParentEnvironment: false,
      runInShell: runInShell,
      mode: mode,
    );
  }

  /// Runs `git` with [arguments] under the credential-plan env policy.
  static Future<ProcessResult> git(
    List<String> arguments, {
    required ProcessEnvironmentPlan plan,
    String? workingDirectory,
    Map<String, String>? baseEnvironment,
    bool noSystemConfig = false,
    Encoding stdoutEncoding = systemEncoding,
    Encoding stderrEncoding = systemEncoding,
  }) {
    return run(
      'git',
      arguments,
      env: EnvPolicy.credentialPlan(plan: plan, noSystemConfig: noSystemConfig),
      baseEnvironment: baseEnvironment,
      workingDirectory: workingDirectory,
      stdoutEncoding: stdoutEncoding,
      stderrEncoding: stderrEncoding,
    );
  }

  /// Starts a long-lived `git` subprocess with [arguments] under the credential-plan env policy.
  static Future<Process> gitStart(
    List<String> arguments, {
    required ProcessEnvironmentPlan plan,
    String? workingDirectory,
    Map<String, String>? baseEnvironment,
    bool noSystemConfig = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    return start(
      'git',
      arguments,
      env: EnvPolicy.credentialPlan(plan: plan, noSystemConfig: noSystemConfig),
      baseEnvironment: baseEnvironment,
      workingDirectory: workingDirectory,
      mode: mode,
    );
  }

  static Map<String, String> _resolveEnvironment(EnvPolicy policy, {Map<String, String>? baseEnvironment}) {
    return switch (policy) {
      _PassThroughEnvPolicy(:final environment) => Map<String, String>.from(
        environment ?? (baseEnvironment ?? Platform.environment),
      ),
      _SanitizeEnvPolicy(:final allowlist, :final extraEnvironment, :final sensitivePatterns) => sanitize(
        baseEnvironment: baseEnvironment,
        allowlist: allowlist,
        extraEnvironment: extraEnvironment,
        sensitivePatterns: sensitivePatterns,
      ),
      _MinimalEnvPolicy(:final extraEnvironment) => sanitize(
        baseEnvironment: baseEnvironment,
        allowlist: defaultBashStepEnvAllowlist,
        extraEnvironment: extraEnvironment,
      ),
      _CredentialPlanEnvPolicy(:final plan, :final noSystemConfig) => sanitize(
        baseEnvironment: baseEnvironment,
        allowlist: defaultGitEnvAllowlist,
        extraEnvironment: {...plan.environment, if (noSystemConfig) 'GIT_CONFIG_NOSYSTEM': '1'},
      ),
    };
  }

  static bool _isSensitive(String key, List<Pattern> patterns) {
    for (final pattern in patterns) {
      if (_matchesPattern(key, pattern)) return true;
    }
    return false;
  }

  static bool _matchesAllowlist(String key, List<String> allowlist) {
    for (final allowed in allowlist) {
      if (allowed.endsWith('*')) {
        final prefix = allowed.substring(0, allowed.length - 1);
        if (key.startsWith(prefix)) return true;
        continue;
      }
      if (key == allowed) return true;
    }
    return false;
  }

  static bool _matchesPattern(String input, Pattern pattern) {
    return switch (pattern) {
      RegExp() => pattern.hasMatch(input),
      String() => input == pattern,
      _ => input.contains(pattern.toString()),
    };
  }
}

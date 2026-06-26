import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show ClaudeProviderOptions, ProviderIdentity;
import 'package:dartclaw_security/dartclaw_security.dart' show EnvPolicy, SafeProcess;

import '../workflow/skill_introspector.dart';

typedef SkillProbeRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments, {Map<String, String>? environment});

typedef SkillProbeEnvironmentBuilder = Map<String, String> Function(String provider);

/// CLI-backed [SkillIntrospector] with per-provider/executable in-flight caching.
final class CliSkillIntrospector implements SkillIntrospector {
  final SkillProbeRunner _runner;
  final Map<String, String> _environment;
  final SkillProbeEnvironmentBuilder? _environmentForProvider;
  final _cache = <_SkillProbeKey, Future<Set<String>>>{};

  CliSkillIntrospector({
    SkillProbeRunner? runner,
    Map<String, String> environment = const <String, String>{},
    SkillProbeEnvironmentBuilder? environmentForProvider,
  }) : _runner = runner ?? _defaultRunner,
       _environment = Map.unmodifiable(environment),
       _environmentForProvider = environmentForProvider;

  @override
  Future<Set<String>> listAvailable({
    required String provider,
    String? executable,
    Map<String, dynamic> providerOptions = const <String, dynamic>{},
  }) {
    final resolvedExecutable = executable?.trim().isNotEmpty == true
        ? executable!.trim()
        : _defaultExecutable(provider);
    final inheritUserSettings = ClaudeProviderOptions.inheritUserSettings(providerOptions);
    final probeProvider = _probeProvider(provider, resolvedExecutable, providerOptions);
    final key = _SkillProbeKey(
      provider: probeProvider,
      executable: resolvedExecutable,
      inheritUserSettings: inheritUserSettings,
    );
    final cached = _cache[key];
    if (cached != null) return cached;

    final probe = _probe(
      provider: probeProvider,
      providerId: provider,
      executable: resolvedExecutable,
      inheritUserSettings: inheritUserSettings,
    );
    _cache[key] = probe;
    // Drop the cache entry once the probe settles. Use statement bodies so the
    // callbacks return void — an arrow body would hand back the cached future
    // itself, and on a probe rejection that re-adopts the error into the
    // unawaited continuation as an unhandled async error.
    unawaited(
      probe.then<void>(
        (_) {
          _cache.remove(key);
        },
        onError: (Object error, StackTrace stackTrace) {
          _cache.remove(key);
        },
      ),
    );
    return probe;
  }

  Future<Set<String>> _probe({
    required String provider,
    required String providerId,
    required String executable,
    required bool inheritUserSettings,
  }) async {
    final args = switch (provider) {
      'claude' => <String>[
        // Env-scrub hardening requires an explicit allowlist; this probe uses no tools.
        '--allowedTools',
        '',
        if (!inheritUserSettings) ...['--setting-sources', 'project'],
        '-p',
        skillIntrospectionPrompt,
      ],
      'codex' => <String>[
        'exec',
        '--skip-git-repo-check',
        '--ephemeral',
        '--sandbox',
        'read-only',
        '-c',
        'approval_policy="never"',
        skillIntrospectionPrompt,
      ],
      _ => throw StateError('No skill introspection command is configured for provider "$provider".'),
    };
    final environment = _environmentForProvider?.call(providerId) ?? _environment;
    final result = await _runner(executable, args, environment: environment.isEmpty ? null : environment);
    if (result.exitCode != 0) {
      // The real failure (e.g. an auth error) is reported on stdout; stderr
      // often carries only the benign CLAUDE_CODE_SUBPROCESS_ENV_SCRUB
      // hardening notice. Surface stdout first so a harmless warning never
      // masks the actual cause.
      final raw = (result.stdout ?? '').toString().trim();
      final stdoutText = _extractPlainText(raw).trim();
      // _extractPlainText can blank a JSON envelope whose `result` is empty;
      // never let a non-empty stdout cause vanish behind the benign env-scrub
      // stderr warning.
      final cause = stdoutText.isNotEmpty ? stdoutText : raw;
      final stderr = (result.stderr ?? '').toString().trim();
      final detail = <String>[if (cause.isNotEmpty) cause, if (stderr.isNotEmpty) 'stderr: $stderr'].join('; ');
      throw StateError(
        'Skill introspection failed for provider "$provider" with exit code ${result.exitCode}'
        '${detail.isEmpty ? '' : ': $detail'}',
      );
    }
    return _parseSkillNames((result.stdout ?? '').toString());
  }

  static Set<String> _parseSkillNames(String stdout) {
    final text = _extractPlainText(stdout).trim();
    if (text.isEmpty) return const <String>{};
    return text.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toSet();
  }

  static String _extractPlainText(String stdout) {
    final trimmed = stdout.trim();
    if (trimmed.isEmpty) return '';
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final result = decoded['result'];
        if (result is String) return result;
      }
    } on FormatException {
      // Plain text is the expected response shape.
    }
    return stdout;
  }

  static String _defaultExecutable(String provider) => switch (provider) {
    'claude' => 'claude',
    'codex' => 'codex',
    _ => provider,
  };

  static String _probeProvider(String provider, String executable, Map<String, dynamic> providerOptions) {
    return ProviderIdentity.resolveFamily(provider, options: providerOptions, executable: executable);
  }

  static Future<ProcessResult> _defaultRunner(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) {
    return SafeProcess.run(
      executable,
      arguments,
      env: EnvPolicy.passthrough(environment: environment ?? const <String, String>{}),
    );
  }
}

final class _SkillProbeKey {
  final String provider;
  final String executable;
  final bool inheritUserSettings;

  const _SkillProbeKey({required this.provider, required this.executable, required this.inheritUserSettings});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _SkillProbeKey &&
          other.provider == provider &&
          other.executable == executable &&
          other.inheritUserSettings == inheritUserSettings;

  @override
  int get hashCode => Object.hash(provider, executable, inheritUserSettings);
}

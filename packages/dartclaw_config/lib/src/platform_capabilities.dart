import 'dart:io';

/// Policy for running workflow steps that require a Bash-compatible shell.
enum BashShellPolicy {
  /// The platform provides a system POSIX shell.
  systemSh,

  /// The platform requires Git Bash or an equivalent installation.
  gitBashRequired,
}

/// Process-termination behavior supported by the current platform.
enum ProcessTerminationSemantics {
  /// Processes support escalating from POSIX SIGTERM to SIGKILL.
  posixSignalEscalation,

  /// Processes support only the platform's hard-termination behavior.
  hardTerminate,
}

/// Immutable, effect-free platform capability policy.
final class PlatformCapabilities {
  final bool _isWindows;
  final Map<String, String> _environment;

  /// Creates capabilities from injectable platform inputs.
  ///
  /// Omitted inputs use the current process's [Platform] values.
  PlatformCapabilities({String? operatingSystem, Map<String, String>? environment})
    : _isWindows = (operatingSystem ?? Platform.operatingSystem) == 'windows',
      _environment = Map<String, String>.unmodifiable(environment ?? Platform.environment);

  /// Resolves the first nonblank `HOME` or `USERPROFILE` value.
  String? get homeDirectory {
    for (final name in const ['HOME', 'USERPROFILE']) {
      final value = _environment[name];
      if (value != null && value.trim().isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  /// Returns command data for locating [executable] without running a process.
  List<String> executableLookupCommand(String executable) => [_isWindows ? 'where' : 'which', executable];

  /// Reports the shell policy supported by the platform.
  BashShellPolicy get bashShellPolicy => _isWindows ? BashShellPolicy.gitBashRequired : BashShellPolicy.systemSh;

  /// Whether POSIX process signals are available.
  bool get posixSignalsAvailable => !_isWindows;

  /// Reports the platform's process-termination semantics.
  ProcessTerminationSemantics get processTerminationSemantics =>
      _isWindows ? ProcessTerminationSemantics.hardTerminate : ProcessTerminationSemantics.posixSignalEscalation;

  /// Whether POSIX file-permission operations are available.
  bool get posixFilePermissionsAvailable => !_isWindows;

  /// Whether DartClaw's POSIX container-isolation implementation is available.
  bool get containerIsolationAvailable => !_isWindows;
}

/// Describes an unavailable capability or a failed platform lookup.
final class UnsupportedCapabilityError implements Exception {
  /// Capability that could not be used.
  final String capability;

  /// Inputs or platform context attempted by the caller.
  final String attemptedContext;

  /// Caller-owned guidance for resolving or avoiding the failure.
  final String remediation;

  /// Creates a structured platform-capability failure.
  const UnsupportedCapabilityError({
    required this.capability,
    required this.attemptedContext,
    required this.remediation,
  });

  @override
  String toString() => 'Unsupported capability "$capability"; attempted $attemptedContext. $remediation';
}

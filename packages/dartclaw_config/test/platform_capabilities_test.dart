import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('PlatformCapabilities', () {
    test('POSIX exposes the complete capability contract', () {
      final capabilities = PlatformCapabilities(operatingSystem: 'linux', environment: const {'HOME': '/home/dev'});

      expect(capabilities.homeDirectory, '/home/dev');
      expect(capabilities.executableSearchCandidates('dartclaw'), isEmpty);
      expect(capabilities.bashShellPolicy, BashShellPolicy.systemSh);
      expect(capabilities.posixSignalsAvailable, isTrue);
      expect(capabilities.processTerminationSemantics, ProcessTerminationSemantics.posixSignalEscalation);
      expect(capabilities.posixFilePermissionsAvailable, isTrue);
      expect(capabilities.containerIsolationAvailable, isTrue);
    });

    test('Windows exposes the complete capability contract', () {
      final capabilities = PlatformCapabilities(
        operatingSystem: 'windows',
        environment: const {
          'USERPROFILE': r'C:\Users\dev',
          'Path': r'C:\Tools;C:\Program Files\DartClaw',
          'PATHEXT': '.EXE;.CMD',
          'SystemRoot': r'D:\Windows',
        },
      );

      expect(capabilities.homeDirectory, r'C:\Users\dev');
      expect(capabilities.executableSearchCandidates('dartclaw'), [
        r'C:\Tools\dartclaw.EXE',
        r'C:\Tools\dartclaw.CMD',
        r'C:\Program Files\DartClaw\dartclaw.EXE',
        r'C:\Program Files\DartClaw\dartclaw.CMD',
      ]);
      expect(capabilities.windowsSystemExecutable('taskkill.exe'), r'D:\Windows\System32\taskkill.exe');
      expect(capabilities.windowsSystemEnvironment, {'SystemRoot': r'D:\Windows', 'WINDIR': r'D:\Windows'});
      expect(capabilities.bashShellPolicy, BashShellPolicy.gitBashRequired);
      expect(capabilities.posixSignalsAvailable, isFalse);
      expect(capabilities.processTerminationSemantics, ProcessTerminationSemantics.hardTerminate);
      expect(capabilities.posixFilePermissionsAvailable, isFalse);
      expect(capabilities.containerIsolationAvailable, isFalse);
    });

    test('home resolution falls back from blank HOME to USERPROFILE', () {
      final capabilities = PlatformCapabilities(
        operatingSystem: 'windows',
        environment: const {'HOME': '  ', 'USERPROFILE': r'C:\Users\dev'},
      );

      expect(capabilities.homeDirectory, r'C:\Users\dev');
    });

    test('home resolution prefers nonblank HOME over USERPROFILE', () {
      final capabilities = PlatformCapabilities(
        operatingSystem: 'windows',
        environment: const {'HOME': '/preferred/home', 'USERPROFILE': r'C:\Users\dev'},
      );

      expect(capabilities.homeDirectory, '/preferred/home');
    });

    test('home resolution returns null when no nonblank variable exists', () {
      final capabilities = PlatformCapabilities(
        operatingSystem: 'linux',
        environment: const {'HOME': ' ', 'USERPROFILE': ''},
      );

      expect(capabilities.homeDirectory, isNull);
    });

    test('Windows executable search excludes empty PATH entries and invalid system roots', () {
      final capabilities = PlatformCapabilities(
        operatingSystem: 'windows',
        environment: const {'PATH': r';C:\Safe;;', 'SystemRoot': r'.\attacker'},
      );

      expect(capabilities.executableSearchCandidates('tool.exe'), [r'C:\Safe\tool.exe']);
      expect(capabilities.windowsSystemExecutable('taskkill.exe'), r'C:\Windows\System32\taskkill.exe');
    });

    test('structured errors preserve capability, context, and caller remediation', () {
      const error = UnsupportedCapabilityError(
        capability: 'container isolation',
        attemptedContext: 'operating system: windows',
        remediation: 'Run DartClaw on POSIX or WSL.',
      );

      expect(error.capability, 'container isolation');
      expect(error.attemptedContext, 'operating system: windows');
      expect(error.remediation, 'Run DartClaw on POSIX or WSL.');
      expect(
        error.toString(),
        'Unsupported capability "container isolation"; attempted operating system: windows. '
        'Run DartClaw on POSIX or WSL.',
      );
    });
  });
}

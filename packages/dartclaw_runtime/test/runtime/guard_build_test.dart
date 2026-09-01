import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

final _cascade = ToolPolicyCascade();

SecurityConfig _configFromYaml(Map<String, dynamic> guardsYaml) {
  return SecurityConfig(guards: const GuardConfig(enabled: true, failOpen: false), guardsYaml: guardsYaml);
}

void main() {
  late Directory tempDir;
  late String dataDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('guard_build_test_');
    dataDir = tempDir.path;
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('buildGuardsFromConfig', () {
    test('valid config (no extras) returns success with 4+ guards', () {
      final result = buildGuardsFromConfig(
        securityConfig: const SecurityConfig.defaults(),
        dataDir: dataDir,
        toolPolicyCascade: _cascade,
      );

      expect(result, isA<GuardBuildSuccess>());
      final success = result as GuardBuildSuccess;
      // CommandGuard, FileGuard, NetworkGuard, ToolPolicyGuard
      expect(success.guards.length, greaterThanOrEqualTo(4));
    });

    test('guard types are correct: CommandGuard, FileGuard, NetworkGuard present', () {
      final result = buildGuardsFromConfig(
        securityConfig: const SecurityConfig.defaults(),
        dataDir: dataDir,
        toolPolicyCascade: _cascade,
      );

      final success = result as GuardBuildSuccess;
      final names = success.guards.map((g) => g.name).toList();
      expect(names, isNot(contains('input-sanitizer')));
      expect(names, contains('command'));
      expect(names, contains('file'));
      expect(names, contains('network'));
    });

    group('invalid regex', () {
      test('invalid command.extra_blocked_patterns regex returns GuardBuildFailure', () {
        final result = buildGuardsFromConfig(
          securityConfig: _configFromYaml({
            'command': {
              'extra_blocked_patterns': ['[invalid regex'],
            },
          }),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildFailure>());
        final failure = result as GuardBuildFailure;
        expect(failure.errors, hasLength(1));
        expect(failure.errors.single, contains('command.extra_blocked_patterns'));
        expect(failure.errors.single, contains('[invalid regex'));
      });

      test('invalid network.extra_exfil_patterns regex returns GuardBuildFailure', () {
        final result = buildGuardsFromConfig(
          securityConfig: _configFromYaml({
            'network': {
              'extra_exfil_patterns': ['(unclosed group'],
            },
          }),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildFailure>());
        final failure = result as GuardBuildFailure;
        expect(failure.errors.single, contains('network.extra_exfil_patterns'));
      });
    });

    group('repeated extras', () {
      test('a repeated command.extra_blocked_patterns entry builds without a deduplication claim', () {
        // Nothing is removed from the built guard, so the build makes no claim
        // that anything was.
        final result = buildGuardsFromConfig(
          securityConfig: _configFromYaml({
            'command': {
              'extra_blocked_patterns': ['rm -rf', 'rm -rf'],
            },
          }),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildSuccess>());
        final commandGuard = (result as GuardBuildSuccess).guards.whereType<CommandGuard>().single;
        final defaults = CommandGuardConfig.defaults();
        expect(commandGuard.config.destructivePatterns.length, defaults.destructivePatterns.length + 2);
      });

      test('a repeated file.extra_rules entry builds without a deduplication claim', () {
        final result = buildGuardsFromConfig(
          securityConfig: _configFromYaml({
            'file': {
              'extra_rules': [
                {'pattern': '/tmp/secret', 'level': 'no_access'},
                {'pattern': '/tmp/secret', 'level': 'no_access'},
              ],
            },
          }),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildSuccess>());
        final fileGuard = (result as GuardBuildSuccess).guards.whereType<FileGuard>().single;
        expect(fileGuard.config.rules.where((r) => r.pattern == '/tmp/secret'), hasLength(2));
      });

      test('a repeated network.extra_exfil_patterns entry builds successfully', () {
        final result = buildGuardsFromConfig(
          securityConfig: _configFromYaml({
            'network': {
              'extra_exfil_patterns': [r'\bsecret\b', r'\bsecret\b'],
            },
          }),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildSuccess>());
      });
    });

    group('conflict detection', () {
      test('conflicting file.extra_rules (same pattern, different level) returns GuardBuildFailure', () {
        final result = buildGuardsFromConfig(
          securityConfig: _configFromYaml({
            'file': {
              'extra_rules': [
                {'pattern': '/tmp/secret', 'level': 'no_access'},
                {'pattern': '/tmp/secret', 'level': 'read_only'}, // conflict: same pattern, different level
              ],
            },
          }),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildFailure>());
        final failure = result as GuardBuildFailure;
        expect(failure.errors, hasLength(1));
        expect(failure.errors.single, contains('/tmp/secret'));
        expect(failure.errors.single, contains('conflicting'));
      });
    });

    group('file rule structural validation', () {
      test('non-list file.extra_rules returns GuardBuildFailure', () {
        final result = buildGuardsFromConfig(
          securityConfig: _configFromYaml({
            'file': {'extra_rules': 'not-a-list'},
          }),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildFailure>());
        final failure = result as GuardBuildFailure;
        expect(failure.errors.single, contains('must be a list'));
      });

      test('non-map file.extra_rules entry returns GuardBuildFailure', () {
        final result = buildGuardsFromConfig(
          securityConfig: _configFromYaml({
            'file': {
              'extra_rules': ['**/secret/**'],
            },
          }),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildFailure>());
        final failure = result as GuardBuildFailure;
        expect(failure.errors.single, contains('rule must be an object'));
      });

      test('missing or empty pattern returns GuardBuildFailure', () {
        final result = buildGuardsFromConfig(
          securityConfig: _configFromYaml({
            'file': {
              'extra_rules': [
                {'level': 'no_access'},
                {'pattern': ' ', 'level': 'read_only'},
              ],
            },
          }),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildFailure>());
        final failure = result as GuardBuildFailure;
        expect(failure.errors, hasLength(2));
        expect(failure.errors.join('\n'), contains('pattern must be a non-empty string'));
      });

      test('missing or invalid level returns GuardBuildFailure', () {
        final result = buildGuardsFromConfig(
          securityConfig: _configFromYaml({
            'file': {
              'extra_rules': [
                {'pattern': '**/missing-level/**'},
                {'pattern': '**/bad-level/**', 'level': 'write_only'},
              ],
            },
          }),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildFailure>());
        final failure = result as GuardBuildFailure;
        expect(failure.errors, hasLength(2));
        expect(failure.errors.join('\n'), contains('must be one of'));
      });
    });

    group('edge cases', () {
      test('empty guardsYaml uses defaults — returns success', () {
        final result = buildGuardsFromConfig(
          securityConfig: const SecurityConfig(guardsYaml: {}),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildSuccess>());
      });

      test('base list carries no per-runner tool filter — those are layered per runner', () {
        final result = buildGuardsFromConfig(
          securityConfig: const SecurityConfig.defaults(),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        final success = result as GuardBuildSuccess;
        expect(success.guards.whereType<TaskToolFilterGuard>(), isEmpty);
      });

      test('multiple invalid patterns aggregate all errors into single failure', () {
        final result = buildGuardsFromConfig(
          securityConfig: _configFromYaml({
            'command': {
              'extra_blocked_patterns': ['[bad1'],
            },
            'network': {
              'extra_exfil_patterns': ['[bad2'],
            },
          }),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildFailure>());
        final failure = result as GuardBuildFailure;
        expect(failure.errors, hasLength(2));
      });
    });
  });
}

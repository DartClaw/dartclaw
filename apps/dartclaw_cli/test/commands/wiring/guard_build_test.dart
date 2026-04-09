import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

const _cascade = ToolPolicyCascade();

SecurityConfig _configFromYaml(Map<String, dynamic> guardsYaml) {
  return SecurityConfig(
    guards: const GuardConfig(enabled: true, failOpen: false),
    guardsYaml: guardsYaml,
  );
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
      // InputSanitizer, CommandGuard, FileGuard, NetworkGuard, ToolPolicyGuard
      expect(success.guards.length, greaterThanOrEqualTo(4));
      expect(success.warnings, isEmpty);
    });

    test('guard types are correct: InputSanitizer, CommandGuard, FileGuard, NetworkGuard present', () {
      final result = buildGuardsFromConfig(
        securityConfig: const SecurityConfig.defaults(),
        dataDir: dataDir,
        toolPolicyCascade: _cascade,
      );

      final success = result as GuardBuildSuccess;
      final names = success.guards.map((g) => g.name).toList();
      expect(names, contains('input-sanitizer'));
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

      test('invalid input_sanitizer.extra_patterns regex returns GuardBuildFailure', () {
        final result = buildGuardsFromConfig(
          securityConfig: _configFromYaml({
            'input_sanitizer': {
              'extra_patterns': ['*bad'],
            },
          }),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildFailure>());
        final failure = result as GuardBuildFailure;
        expect(failure.errors.single, contains('input_sanitizer.extra_patterns'));
      });
    });

    group('duplicate detection', () {
      test('duplicate command.extra_blocked_patterns deduplicated — returns success with warning', () {
        final result = buildGuardsFromConfig(
          securityConfig: _configFromYaml({
            'command': {
              'extra_blocked_patterns': ['rm -rf', 'rm -rf'], // duplicate
            },
          }),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildSuccess>());
        final success = result as GuardBuildSuccess;
        expect(success.warnings, hasLength(1));
        expect(success.warnings.single, contains('duplicate'));
        expect(success.warnings.single, contains('rm -rf'));
      });

      test('duplicate file.extra_rules (same pattern+level) returns success with warning', () {
        final result = buildGuardsFromConfig(
          securityConfig: _configFromYaml({
            'file': {
              'extra_rules': [
                {'pattern': '/tmp/secret', 'level': 'no_access'},
                {'pattern': '/tmp/secret', 'level': 'no_access'}, // exact duplicate
              ],
            },
          }),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildSuccess>());
        final success = result as GuardBuildSuccess;
        expect(success.warnings, hasLength(1));
        expect(success.warnings.single, contains('/tmp/secret'));
      });

      test('duplicate network.extra_exfil_patterns returns success with warning', () {
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
        final success = result as GuardBuildSuccess;
        expect(success.warnings, hasLength(1));
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

    group('edge cases', () {
      test('empty guardsYaml uses defaults — returns success', () {
        final result = buildGuardsFromConfig(
          securityConfig: const SecurityConfig(guardsYaml: {}),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
        );

        expect(result, isA<GuardBuildSuccess>());
      });

      test('TaskToolFilterGuard is appended when provided', () {
        final ttfg = TaskToolFilterGuard();

        final result = buildGuardsFromConfig(
          securityConfig: const SecurityConfig.defaults(),
          dataDir: dataDir,
          toolPolicyCascade: _cascade,
          taskToolFilterGuard: ttfg,
        );

        final success = result as GuardBuildSuccess;
        expect(success.guards.last, same(ttfg));
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

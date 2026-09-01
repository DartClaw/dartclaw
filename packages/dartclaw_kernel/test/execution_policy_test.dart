import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('ExecutionMode', () {
    test('parses the accepted YAML spellings case- and space-insensitively', () {
      expect(ExecutionMode.fromYaml('host'), ExecutionMode.host);
      expect(ExecutionMode.fromYaml(' Container '), ExecutionMode.container);
    });

    test('returns null for unknown values instead of guessing a mode', () {
      expect(ExecutionMode.fromYaml('sandbox'), isNull);
      expect(ExecutionMode.fromYaml(''), isNull);
    });
  });

  group('ExecutionPolicy invariants', () {
    test('host execution carries no container profile', () {
      const policy = ExecutionPolicy.host();

      expect(policy.mode, ExecutionMode.host);
      expect(policy.containerProfile, isNull);
      expect(policy.isContainer, isFalse);
    });

    test('container execution carries its profile', () {
      const policy = ExecutionPolicy.container('restricted');

      expect(policy.mode, ExecutionMode.container);
      expect(policy.containerProfile, 'restricted');
      expect(policy.isContainer, isTrue);
    });

    test('rejects a profile on host execution — a profile is not a location', () {
      expect(() => ExecutionPolicy.of(ExecutionMode.host, 'workspace'), throwsFormatException);
    });

    test('rejects container execution without a profile', () {
      expect(() => ExecutionPolicy.of(ExecutionMode.container, null), throwsFormatException);
    });
  });

  group('identity', () {
    test('policies differing only by profile are not equal', () {
      expect(
        const ExecutionPolicy.container('workspace'),
        isNot(equals(const ExecutionPolicy.container('restricted'))),
      );
    });

    test('host is never equal to any container policy', () {
      expect(const ExecutionPolicy.host(), isNot(equals(const ExecutionPolicy.container('workspace'))));
    });

    test('equal policies share a hash code so they can key reuse decisions', () {
      expect(
        const ExecutionPolicy.container('workspace').hashCode,
        const ExecutionPolicy.container('workspace').hashCode,
      );
    });

    test('describe renders both axes for diagnostics', () {
      expect(const ExecutionPolicy.host().describe(), 'host');
      expect(const ExecutionPolicy.container('restricted').describe(), 'container/restricted');
    });
  });

  group('serialization', () {
    test('round-trips container execution', () {
      const policy = ExecutionPolicy.container('restricted');

      expect(ExecutionPolicy.fromJson(policy.toJson()), policy);
    });

    test('round-trips host execution and omits the profile key', () {
      const policy = ExecutionPolicy.host();

      expect(policy.toJson(), {'mode': 'host'});
      expect(ExecutionPolicy.fromJson(policy.toJson()), policy);
    });

    test('rejects an unknown persisted mode', () {
      expect(() => ExecutionPolicy.fromJson({'mode': 'vm'}), throwsFormatException);
    });
  });
}

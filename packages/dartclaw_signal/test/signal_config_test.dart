import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:test/test.dart';

void main() {
  group('SignalConfig', () {
    test('fromYaml parses all fields', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({
        'enabled': true,
        'phone_number': '+1234567890',
        'executable': '/usr/local/bin/signal-cli',
        'host': '0.0.0.0',
        'port': 9090,
        'max_chunk_size': 2000,
      }, warns);
      expect(warns, isEmpty);
      expect(config.enabled, isTrue);
      expect(config.phoneNumber, '+1234567890');
      expect(config.executable, '/usr/local/bin/signal-cli');
      expect(config.host, '0.0.0.0');
      expect(config.port, 9090);
      expect(config.maxChunkSize, 2000);
    });

    test('fromYaml uses defaults for missing fields', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({}, warns);
      expect(warns, isEmpty);
      expect(config.enabled, isFalse);
      expect(config.phoneNumber, '');
      expect(config.executable, 'signal-cli');
      expect(config.host, '127.0.0.1');
      expect(config.port, 8080);
    });

    test('fromYaml warns on invalid types', () {
      final warns = <String>[];
      SignalConfig.fromYaml({
        'enabled': 'yes',
        'phone_number': 123,
        'executable': 456,
        'host': true,
        'port': 'big',
        'max_chunk_size': 'big',
      }, warns);
      expect(warns, hasLength(6));
    });

    test('fromYaml warns on out-of-range port and uses default', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({'port': 0}, warns);
      expect(warns, hasLength(1));
      expect(warns.first, contains('1-65535'));
      expect(config.port, 8080);

      final warns2 = <String>[];
      final config2 = SignalConfig.fromYaml({'port': 70000}, warns2);
      expect(warns2, hasLength(1));
      expect(config2.port, 8080);
    });

    test('fromYaml rejects non-positive max chunk sizes', () {
      final warns = <String>[];

      final config = SignalConfig.fromYaml({'max_chunk_size': 0}, warns);

      expect(config.maxChunkSize, 4000);
      expect(warns.single, contains('max_chunk_size'));
    });

    test('registered access vocabularies match the shared mappers', () {
      expect(
        ConfigMeta.fields['channels.signal.dm_access']!.allowedValues!.toSet(),
        DmAccessMode.values.map((value) => value.name).toSet(),
      );
      expect(
        ConfigMeta.fields['channels.signal.group_access']!.allowedValues!.toSet(),
        GroupAccessMode.values.map((value) => value.name).toSet(),
      );
    });

    test('invalid access values keep channel-specific warnings and defaults', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({'dm_access': 'bogus', 'group_access': 'pairing'}, warns);

      expect(config.dmAccess, DmAccessMode.allowlist);
      expect(config.groupAccess, GroupAccessMode.disabled);
      expect(warns, [
        'Invalid signal.dm_access: "bogus" — using default',
        'Invalid signal.group_access: "pairing" — using default',
      ]);
    });

    test('declared port endpoints are accepted', () {
      final lowWarnings = <String>[];
      final highWarnings = <String>[];

      expect(SignalConfig.fromYaml({'port': 1}, lowWarnings).port, 1);
      expect(SignalConfig.fromYaml({'port': 65535}, highWarnings).port, 65535);
      expect(lowWarnings, isEmpty);
      expect(highWarnings, isEmpty);
    });
  });

  // TD-142: the API can no longer store an unusable dm_allowlist entry, so a
  // hand-written `dartclaw.yaml` is the one way one still arrives. It is named
  // at load rather than costing the operator their access silently.
  group('dm_allowlist entries that can never match are named at load', () {
    List<String> warningsFor(List<String> allowlist) {
      final warns = <String>[];
      SignalConfig.fromYaml({'enabled': true, 'dm_allowlist': allowlist}, warns);
      return warns;
    }

    test('a mixed-case UUID is named with the spelling to rewrite it as', () {
      final warns = warningsFor(['A1B2C3D4-E5F6-7890-ABCD-EF1234567890']);
      expect(warns, hasLength(1));
      expect(warns.single, contains('A1B2C3D4-E5F6-7890-ABCD-EF1234567890'));
      expect(warns.single, contains('a1b2c3d4-e5f6-7890-abcd-ef1234567890'));
      expect(warns.single, contains('never match'));
    });

    test('a malformed phone is named', () {
      expect(warningsFor(['+abc']).single, contains('+abc'));
    });

    test('a lowercase UUID and a well-formed phone are silent', () {
      expect(warningsFor(['a1b2c3d4-e5f6-7890-abcd-ef1234567890', '+15551234567']), isEmpty);
    });
  });
}

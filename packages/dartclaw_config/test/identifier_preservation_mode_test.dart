import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('IdentifierPreservationMode', () {
    test('preserves exact wire values', () {
      expect(IdentifierPreservationMode.fromJsonString('strict'), IdentifierPreservationMode.strict);
      expect(IdentifierPreservationMode.strict.toJson(), 'strict');
      expect(IdentifierPreservationMode.fromJsonString('off'), IdentifierPreservationMode.off);
      expect(IdentifierPreservationMode.off.toJson(), 'off');
      expect(IdentifierPreservationMode.fromJsonString('custom'), IdentifierPreservationMode.custom);
      expect(IdentifierPreservationMode.custom.toJson(), 'custom');
    });

    test('rejects unknown values with known values listed', () {
      expect(
        () => IdentifierPreservationMode.fromJsonString('relaxed'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('strict'), contains('off'), contains('custom')),
          ),
        ),
      );
    });
  });

  group('context.identifier_preservation', () {
    for (final entry in const {
      'strict': IdentifierPreservationMode.strict,
      'off': IdentifierPreservationMode.off,
      'custom': IdentifierPreservationMode.custom,
    }.entries) {
      test('parses ${entry.key}', () {
        final config = DartclawConfig.load(
          fileReader: (path) => path == '/home/user/.dartclaw/dartclaw.yaml'
              ? '''
context:
  identifier_preservation: ${entry.key}
'''
              : null,
          env: {'HOME': '/home/user'},
        );

        expect(config.context.identifierPreservation, entry.value);
        expect(config.warnings, isEmpty);
      });
    }

    test('invalid value warns and keeps strict default', () {
      final config = DartclawConfig.load(
        fileReader: (path) => path == '/home/user/.dartclaw/dartclaw.yaml'
            ? '''
context:
  identifier_preservation: relaxed
'''
            : null,
        env: {'HOME': '/home/user'},
      );

      expect(config.context.identifierPreservation, IdentifierPreservationMode.strict);
      expect(
        config.warnings,
        anyElement(
          allOf(contains('context.identifier_preservation'), contains('relaxed'), contains('strict, off, custom')),
        ),
      );
    });
  });
}

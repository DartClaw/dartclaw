import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_kernel/src/config_numeric_bounds.dart';
import 'package:test/test.dart';

void main() {
  test('delegates the decision to FieldConstraints and saturates declared bounds', () {
    final violation = ConfigNumericBounds.evaluate('context.warning_threshold', 3, requireMin: true, requireMax: true);

    expect(violation, isA<OutOfRange>());
    expect(violation!.field, same(ConfigMeta.fields['context.warning_threshold']));
    expect(ConfigNumericBounds.clamp('context.warning_threshold', 3), 50);
    expect(ConfigNumericBounds.clamp('context.warning_threshold', 200), 99);
  });

  test('fails when a path or required bound is absent', () {
    expect(() => ConfigNumericBounds.evaluate('missing.path', 1), throwsStateError);
    expect(() => ConfigNumericBounds.evaluate('memory.max_bytes', 1, requireMax: true), throwsStateError);
  });
}

import 'package:dartclaw_acp/dartclaw_acp.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  test('ACP reports model and effort unavailable because session/prompt ignores them', () {
    final harness = AcpHarness(cwd: '/tmp');
    expect(EffectiveContextCapabilities.of(harness).toJson(), {
      'model': false,
      'effort': false,
      'models': <String>[],
      'efforts': <String>[],
    });
  });
}

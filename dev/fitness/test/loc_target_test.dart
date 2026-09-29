import 'package:test/test.dart';

import '../../tools/loc_target.dart';

void main() {
  test('LOC targets allow smaller overages and fail at exactly ten percent', () {
    expect(locExceedsTarget(1099, 1000), isFalse);
    expect(locExceedsTarget(1100, 1000), isTrue);
    expect(locExceedsTarget(1101, 1000), isTrue);
  });

  test('small targets use the exact ratio rather than rounded headroom', () {
    expect(locExceedsTarget(1, 1), isFalse);
    expect(locExceedsTarget(2, 1), isTrue);
    expect(locExceedsTarget(10, 9), isTrue);
    expect(locExceedsTarget(9, 9), isFalse);
  });
}

import 'package:test/test.dart';

import '../total.dart';

void main() {
  test('total sums positive and negative integers and handles empty input', () {
    expect(total([2, 3, -1]), 4);
    expect(total([]), 0);
    expect(total([-4, -2]), -6);
  });
}

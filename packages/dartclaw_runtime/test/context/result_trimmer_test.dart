import 'dart:convert';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('ResultTrimmer', () {
    test('small results are unchanged', () {
      final trimmer = ResultTrimmer(maxBytes: 1024);
      const small = 'Hello, world!';
      expect(trimmer.trim(small), small);
    });

    test('result at exact max is unchanged', () {
      final trimmer = ResultTrimmer(maxBytes: 100);
      final exact = 'a' * 100;
      expect(trimmer.trim(exact), exact);
    });

    test('oversized result is trimmed', () {
      final trimmer = ResultTrimmer(maxBytes: 100);
      final large = 'x' * 10000;
      final result = trimmer.trim(large);

      expect(result.length, lessThan(large.length));
      expect(result, contains('...[trimmed'));
      expect(result, contains('bytes]...'));
    });

    test('trimmed result preserves head and tail', () {
      final trimmer = ResultTrimmer(maxBytes: 100);
      // Create a string with distinct head and tail
      final large = 'HEAD${'m' * 10000}TAIL';
      final result = trimmer.trim(large);

      expect(result, startsWith('HEAD'));
      expect(result, endsWith('TAIL'));
    });

    test('the trimmed byte count is what the caller did not receive', () {
      final result = ResultTrimmer(maxBytes: 8 * 1024).trim('a' * 100000);

      final marker = RegExp(r'\n\.\.\.\[trimmed (\d+) bytes\]\.\.\.\n').firstMatch(result)!;
      final kept = utf8.encode(result).length - marker.group(0)!.length;
      expect(int.parse(marker.group(1)!), 100000 - kept);
    });

    test('the cap bounds what comes back, not merely when to cut', () {
      for (final cap in const [64, 512, 4096, 50 * 1024]) {
        for (final unit in const ['a', '\u00e9', '\u4e2d', '\u{1F600}']) {
          final result = ResultTrimmer(maxBytes: cap).trim(unit * 50000);
          expect(utf8.encode(result).length, lessThanOrEqualTo(cap), reason: 'cap $cap, unit $unit');
          expect(result, isNot(contains('trimmed -')), reason: 'cap $cap, unit $unit');
        }
      }
    });

    test('a cap smaller than the input never grows it', () {
      final result = ResultTrimmer(maxBytes: 1024).trim('x' * 3000);

      expect(utf8.encode(result).length, lessThanOrEqualTo(1024));
    });

    test('raising the cap lets more through untouched, it does not widen the excerpt', () {
      final huge = 'a' * (4 * 1024 * 1024);

      final atDefault = ResultTrimmer().trim(huge);
      final atMegabyte = ResultTrimmer(maxBytes: 1024 * 1024).trim(huge);

      expect(utf8.encode(atMegabyte).length, utf8.encode(atDefault).length);
      expect(utf8.encode(atDefault).length, lessThan(2 * 2048 + 64));
    });

    test('a multibyte excerpt is a real prefix and suffix of the input', () {
      // 3-byte characters land off a 2048-byte slice boundary, which is where a
      // byte-position slice splits a character if the ends are not realigned.
      for (final unit in const ['\u{1F600}', '\u4e2d', '\u00e9']) {
        for (final pad in const [0, 1, 2]) {
          final input = '${'a' * pad}${unit * 6000}';
          final result = ResultTrimmer(maxBytes: 5000).trim(input);

          final parts = result.split(RegExp(r'\n\.\.\.\[trimmed \d+ bytes\]\.\.\.\n'));
          expect(parts, hasLength(2), reason: 'unit $unit, pad $pad');
          expect(input, startsWith(parts[0]), reason: 'unit $unit, pad $pad');
          expect(input, endsWith(parts[1]), reason: 'unit $unit, pad $pad');
          expect(parts[0], isNotEmpty, reason: 'unit $unit, pad $pad');
          expect(parts[1], isNotEmpty, reason: 'unit $unit, pad $pad');
        }
      }
    });

    test('default maxBytes is 50KB', () {
      final trimmer = ResultTrimmer();
      final underLimit = 'a' * (50 * 1024);
      expect(trimmer.trim(underLimit), underLimit);
    });
  });
}

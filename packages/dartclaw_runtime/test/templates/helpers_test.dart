import 'package:dartclaw_runtime/src/templates/helpers.dart';
import 'package:test/test.dart';

void main() {
  group('formatUptime', () {
    test('formats durations correctly', () {
      expect(formatUptime(0), '0m');
      expect(formatUptime(300), '5m');
      expect(formatUptime(5400), '1h 30m');
      expect(formatUptime(90120), '1d 1h 2m');
    });
  });

  group('formatBytes', () {
    test('formats sizes correctly', () {
      expect(formatBytes(500), '500 B');
      expect(formatBytes(2048), '2 KB');
      expect(formatBytes(2 * 1024 * 1024), '2.0 MB');
    });
  });

  group('formatRelativeTime', () {
    test('stays relative through 30 elapsed days', () {
      expect(formatRelativeTime(DateTime.now()), 'just now');
      expect(formatRelativeTime(DateTime.now().subtract(const Duration(minutes: 5))), '5m ago');
      expect(formatRelativeTime(DateTime.now().subtract(const Duration(hours: 3))), '3h ago');
      expect(formatRelativeTime(DateTime.now().subtract(const Duration(days: 29))), '29d ago');
      expect(formatRelativeTime(DateTime.now().subtract(const Duration(days: 30))), '30d ago');
    });

    test('falls back to an absolute short date from day 31', () {
      // "347d ago" is not a date a human can place. Past a month the absolute
      // date carries more information than the elapsed count.
      final day31 = DateTime.now().subtract(const Duration(days: 31));
      final formatted = formatRelativeTime(day31);
      expect(formatted, isNot(contains('ago')));
      expect(formatted, contains(day31.day.toString()));

      final old = DateTime.now().subtract(const Duration(days: 400));
      expect(formatRelativeTime(old), isNot(contains('ago')));
    });

    test('omits the year within the current local calendar year and states it otherwise', () {
      final now = DateTime.now();
      // A fixed in-year date avoids the ambiguity of counting back from today.
      final sameYear = DateTime(now.year, 1, 5, 10, 0);
      if (now.difference(sameYear).inDays > 30) {
        expect(formatRelativeTime(sameYear), '5 Jan');
      }

      final crossYear = DateTime(now.year - 2, 3, 9, 10, 0);
      expect(formatRelativeTime(crossYear), '9 Mar ${now.year - 2}');
    });

    test('renders the absolute date in server-local time, not UTC', () {
      // A UTC instant late in the day belongs to the next local day east of
      // Greenwich; printing the UTC calendar day would be off by one there.
      final utcInstant = DateTime.utc(2020, 6, 15, 23, 30);
      final local = utcInstant.toLocal();
      expect(formatRelativeTime(utcInstant), '${local.day} ${_month(local.month)} 2020');
    });
  });

  group('formatRelativeTimeIso and isoTitle', () {
    test('absent and unparseable input yield no rendering and no disclosure', () {
      // Every converted call site leans on this: '' lets the template branch to
      // the absent treatment, and a null title makes tl:attr omit the attribute.
      for (final bad in <String?>[null, '', 'not-a-date']) {
        expect(formatRelativeTimeIso(bad), '', reason: 'input: $bad');
        expect(isoTitle(bad), isNull, reason: 'input: $bad');
      }
    });

    test('a parseable instant formats and discloses its source string verbatim', () {
      const iso = '2020-06-15T23:30:00.000Z';
      expect(formatRelativeTimeIso(iso), formatRelativeTime(DateTime.parse(iso)));
      expect(isoTitle(iso), iso);
    });
  });

  group('absentValue', () {
    test('treats only null and the empty string as absent', () {
      expect(absentValue(null).isAbsent, isTrue);
      expect(absentValue('').isAbsent, isTrue);
      expect(absentValue(null).value, isNull);
      expect(absentValue('').value, isNull);
    });

    test('preserves a legitimate zero, string zero and false', () {
      // A computed 0 is knowledge, not a missing field. Rendering it as a dash
      // reports "unknown" for a step count the system knows exactly.
      for (final input in <Object>[0, '0', false, 0.0]) {
        final resolved = absentValue(input);
        expect(resolved.isAbsent, isFalse, reason: '$input must not be absent');
        expect(resolved.value, input, reason: '$input must survive unchanged');
      }
    });

    test('passes non-empty values through untouched', () {
      expect(absentValue('claude').value, 'claude');
      expect(absentValue(' ').isAbsent, isFalse);
      expect(absentValue(' ').value, ' ');
      // Escaping is the template's job (tl:text); the helper never mangles input.
      expect(absentValue('<script>x</script>').value, '<script>x</script>');
    });
  });
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _month(int month) => _months[month - 1];

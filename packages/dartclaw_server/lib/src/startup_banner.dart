import 'dart:io';
import 'dart:math' show max;

import 'version.dart';

/// Builds an ASCII box-framed startup banner for the DartClaw server.
///
/// When [colorize] is true, ANSI codes are used to style the banner.
/// Safe to call with `colorize: false` when stderr is not a TTY.
String startupBanner({
  required String host,
  required int port,
  String name = 'DartClaw',
  String? token,
  bool authEnabled = true,
  bool guardsEnabled = false,
  bool containerEnabled = false,
  List<String> channels = const [],
  bool colorize = false,
}) {
  final title = '$name v$dartclawVersion';
  final baseUrl = 'http://$host:$port';
  // Single clickable URL line — token appended as query param
  final url = token != null ? '$baseUrl/?token=$token' : baseUrl;

  // Key-value pairs for the stats section
  final stats = <(String, String)>[
    ('Auth', authEnabled ? 'token' : 'off'),
    ('Guards', guardsEnabled ? 'on' : 'off'),
    ('Container', containerEnabled ? 'on' : 'off'),
    if (channels.isNotEmpty) ('Channels', channels.join(', ')),
    ('PID', '$pid'),
  ];

  // ANSI helpers
  //   Box border: magenta, Title: bold + bright white,
  //   URL: underline + bright cyan (clickable look), Stats: dim
  final boxOn = colorize ? '\x1B[35m' : '';        // magenta
  final titleOn = colorize ? '\x1B[1;97m' : '';     // bold bright white
  final urlOn = colorize ? '\x1B[4;96m' : '';       // underline bright cyan
  final dimOn = colorize ? '\x1B[2m' : '';          // dim
  final reset = colorize ? '\x1B[0m' : '';

  // Format each stat as "Label .... value" with fixed column width.
  const colWidth = 24;
  String formatStat((String, String) s) {
    final label = s.$1;
    final value = s.$2;
    final dotsNeeded = colWidth - label.length - value.length - 2;
    final dots = dotsNeeded > 1 ? ' ${'.' * dotsNeeded} ' : ' ';
    return '$label$dots$value';
  }

  final formatted = stats.map(formatStat).toList();
  final rows = <String>[];
  for (var i = 0; i < formatted.length; i += 2) {
    if (i + 1 < formatted.length) {
      rows.add('${formatted[i].padRight(colWidth)}  ${formatted[i + 1]}');
    } else {
      rows.add(formatted[i]);
    }
  }

  // Box width: fit all content lines
  var innerWidth = [
    title.length,
    url.length,
    ...rows.map((r) => r.length),
  ].reduce(max);
  innerWidth += 4; // padding (2 each side)

  // Build banner
  final buf = StringBuffer();
  final top = '$boxOn┌${'─' * innerWidth}┐$reset';
  final bottom = '$boxOn└${'─' * innerWidth}┘$reset';
  final empty = _boxRow('', 0, innerWidth, boxOn, reset);

  buf.writeln();
  buf.writeln(top);
  buf.writeln(empty);
  buf.writeln(_boxCenter('$titleOn$title$reset', title.length, innerWidth, boxOn, reset));
  buf.writeln(_boxCenter('$urlOn$url$reset', url.length, innerWidth, boxOn, reset));
  buf.writeln(empty);
  for (final row in rows) {
    buf.writeln(_boxLeft('$dimOn$row$reset', row.length, innerWidth, boxOn, reset));
  }
  buf.writeln(bottom);
  buf.writeln();

  return buf.toString();
}

String _boxRow(String content, int visibleLength, int innerWidth, String boxOn, String reset) {
  final padRight = innerWidth - visibleLength;
  return '$boxOn│$reset$content${' ' * padRight}$boxOn│$reset';
}

String _boxCenter(String content, int visibleLength, int innerWidth, String boxOn, String reset) {
  final pad = (innerWidth - visibleLength) ~/ 2;
  final padRight = innerWidth - visibleLength - pad;
  return '$boxOn│$reset${' ' * pad}$content${' ' * padRight}$boxOn│$reset';
}

String _boxLeft(String content, int visibleLength, int innerWidth, String boxOn, String reset) {
  final padRight = innerWidth - visibleLength - 2;
  return '$boxOn│$reset  $content${' ' * (padRight > 0 ? padRight : 0)}$boxOn│$reset';
}

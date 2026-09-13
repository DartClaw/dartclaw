import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  try {
    final options = _Options.parse(arguments);
    final manifest = _Manifest.read(options.manifest);
    final expected = manifest.expected(options.expectedSets);
    final observed = _readReports(options.reports);

    final unregistered = observed.keys.toSet().difference(manifest.all);
    final missing = expected.difference(observed.keys.toSet());
    final unexpected = observed.keys.toSet().difference(expected);
    final failed = {
      for (final entry in observed.entries)
        if (!entry.value.passing) entry.key,
    };
    if (unregistered.isNotEmpty || missing.isNotEmpty || unexpected.isNotEmpty || failed.isNotEmpty) {
      _fail(
        [
          if (missing.isNotEmpty) 'missing: ${_sorted(missing)}',
          if (failed.isNotEmpty) 'failed or skipped: ${_sorted(failed)}',
          if (unregistered.isNotEmpty) 'unregistered: ${_sorted(unregistered)}',
          if (unexpected.isNotEmpty) 'unexpected: ${_sorted(unexpected)}',
        ].join('\n'),
      );
    }
    stdout.writeln('Contract groups passed: ${_sorted(expected)}');
  } on Object catch (error) {
    _fail(error.toString());
  }
}

Map<String, _GroupResult> _readReports(List<String> paths) {
  final groups = <String, _GroupResult>{};
  final token = RegExp(r'\[contract:([^\]]+)\]');
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) throw FormatException('Report does not exist: $path');
    final lines = file.readAsLinesSync();
    if (lines.isEmpty) throw FormatException('Report is empty: $path');
    final starts = <int, ({String name, bool skipped})>{};
    var sawTerminalDone = false;
    for (var lineNumber = 0; lineNumber < lines.length; lineNumber++) {
      final line = lines[lineNumber].trim();
      if (line.isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        throw FormatException('Malformed JSON in $path at line ${lineNumber + 1}');
      }
      if (decoded is! Map<String, dynamic>) {
        throw FormatException('Reporter event in $path at line ${lineNumber + 1} is not an object');
      }
      if (sawTerminalDone) {
        throw FormatException('Reporter event follows terminal done in $path at line ${lineNumber + 1}');
      }
      switch (decoded['type']) {
        case 'testStart':
          final test = decoded['test'];
          if (test is! Map<String, dynamic> || test['id'] is! int || test['name'] is! String) {
            throw FormatException('Malformed testStart in $path at line ${lineNumber + 1}');
          }
          final metadata = test['metadata'];
          final skip = metadata is Map<String, dynamic> ? metadata['skip'] : null;
          final id = test['id'] as int;
          if (starts.containsKey(id)) throw FormatException('Duplicate testStart $id in $path');
          starts[id] = (name: test['name'] as String, skipped: skip != null && skip != false);
        case 'testDone':
          final id = decoded['testID'];
          if (id is! int) throw FormatException('Malformed testDone in $path at line ${lineNumber + 1}');
          final start = starts.remove(id);
          if (start == null) throw FormatException('testDone $id has no testStart in $path');
          if (decoded['hidden'] == true) continue;
          final match = token.firstMatch(start.name);
          if (match == null) continue;
          final group = groups.putIfAbsent(match.group(1)!, _GroupResult.new);
          group.visible++;
          if (start.skipped || decoded['skipped'] == true || decoded['result'] != 'success') {
            group.failed = true;
          }
        case 'done':
          if (decoded['success'] != true) {
            throw FormatException('Reporter terminal done was not successful in $path');
          }
          sawTerminalDone = true;
      }
    }
    if (starts.isNotEmpty) {
      throw FormatException('Unmatched testStart ids in $path: ${_sorted(starts.keys.map((id) => '$id'))}');
    }
    if (!sawTerminalDone) throw FormatException('Report has no successful terminal done event: $path');
  }
  return groups;
}

Never _fail(String message) {
  stderr.writeln('contract_groups_check: $message');
  exit(1);
}

String _sorted(Iterable<String> values) => (values.toList()..sort()).join(', ');

final class _GroupResult {
  var visible = 0;
  var failed = false;

  bool get passing => visible > 0 && !failed;
}

final class _Manifest {
  const new(this.sets, this.all);

  final Map<String, Set<String>> sets;
  final Set<String> all;

  factory read(String path) {
    final file = File(path);
    if (!file.existsSync()) throw FormatException('Manifest does not exist: $path');
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Manifest must be a JSON object');
    }
    final sets = <String, Set<String>>{};
    final all = <String>{};
    for (final entry in decoded.entries) {
      final values = entry.value;
      if (values is! List || values.any((value) => value is! String)) {
        throw FormatException('Manifest set ${entry.key} must be a string array');
      }
      final set = values.cast<String>().toSet();
      if (set.length != values.length) {
        throw FormatException('Manifest set ${entry.key} contains duplicate ids');
      }
      final duplicates = all.intersection(set);
      if (duplicates.isNotEmpty) {
        throw FormatException('Contract ids classified more than once: ${_sorted(duplicates)}');
      }
      sets[entry.key] = set;
      all.addAll(set);
    }
    return _Manifest(sets, all);
  }

  Set<String> expected(Set<String> names) {
    final unknown = names.difference(sets.keys.toSet());
    if (unknown.isNotEmpty) throw FormatException('Unknown --expect set: ${_sorted(unknown)}');
    return {for (final name in names) ...sets[name]!};
  }
}

final class _Options {
  const new({required this.manifest, required this.expectedSets, required this.reports});

  final String manifest;
  final Set<String> expectedSets;
  final List<String> reports;

  factory parse(List<String> arguments) {
    String? manifest;
    Set<String>? expected;
    final reports = <String>[];
    for (var index = 0; index < arguments.length; index++) {
      final option = arguments[index];
      if (!const {'--manifest', '--expect', '--report'}.contains(option) || index + 1 >= arguments.length) {
        throw const FormatException(
          'Usage: dart run dev/tools/contract_groups_check.dart '
          '--manifest <path> --expect <set,set> --report <path> [--report <path> ...]',
        );
      }
      final value = arguments[++index];
      switch (option) {
        case '--manifest':
          if (manifest != null) throw const FormatException('--manifest may be supplied once');
          manifest = value;
        case '--expect':
          if (expected != null) throw const FormatException('--expect may be supplied once');
          expected = value.split(',').where((name) => name.isNotEmpty).toSet();
        case '--report':
          reports.add(value);
      }
    }
    if (manifest == null || expected == null || expected.isEmpty || reports.isEmpty) {
      throw const FormatException('Required options are --manifest, --expect, and at least one --report');
    }
    return _Options(manifest: manifest, expectedSets: expected, reports: reports);
  }
}

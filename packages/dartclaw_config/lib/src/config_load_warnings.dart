// ignore_for_file: public_member_api_docs

import 'dart:collection';

/// Keeps reload validity typed without breaking parser APIs that accept `List<String>`.
final class ConfigLoadWarnings extends ListBase<String> {
  ConfigLoadWarnings([Iterable<String> warnings = const []])
    : _entries = [for (final warning in warnings) (message: warning, advisory: false)];

  ConfigLoadWarnings.copy(List<String> warnings)
    : _entries = warnings is ConfigLoadWarnings
          ? List<({String message, bool advisory})>.of(warnings._entries)
          : [for (final warning in warnings) (message: warning, advisory: false)];

  final List<({String message, bool advisory})> _entries;

  List<String> get blockingWarnings => [
    for (final entry in _entries)
      if (!entry.advisory) entry.message,
  ];

  void addAdvisory(String warning) => _entries.add((message: warning, advisory: true));

  @override
  int get length => _entries.length;

  @override
  set length(int value) {
    if (value < _entries.length) {
      _entries.removeRange(value, _entries.length);
      return;
    }
    while (_entries.length < value) {
      _entries.add((message: '', advisory: false));
    }
  }

  @override
  String operator [](int index) => _entries[index].message;

  @override
  void operator []=(int index, String value) {
    _entries[index] = (message: value, advisory: false);
  }
}

void addConfigAdvisory(List<String> warnings, String warning) {
  if (warnings case ConfigLoadWarnings collector) {
    collector.addAdvisory(warning);
  } else {
    warnings.add(warning);
  }
}

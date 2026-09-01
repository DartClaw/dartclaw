part of 'dartclaw_config.dart';

HarnessConfig _parseHarness(Map<String, dynamic> yaml, HarnessConfig defaults, List<String> warns) {
  final harnessMap = _sectionMap('harness', yaml, warns);
  if (harnessMap == null) return defaults;

  // Every other Map-valued `harness.<key>` is retained raw for the package
  // that owns it; see `HarnessConfig.sections`.
  final sections = <String, Map<String, dynamic>>{};
  for (final entry in harnessMap.entries) {
    final key = entry.key.toString();
    if (entry.value is Map) {
      sections[key] = Map<String, dynamic>.from(entry.value as Map);
    } else {
      warns.add('Invalid type for harness.$key: "${entry.value.runtimeType}" — skipping');
    }
  }

  return HarnessConfig(sections: sections);
}

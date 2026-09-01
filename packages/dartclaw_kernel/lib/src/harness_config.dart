import 'package:collection/collection.dart';

/// Harness-level runtime controls.
class HarnessConfig {
  /// Raw `harness.<name>` sub-sections, keyed by name.
  ///
  /// This package parses none of them: a harness section is owned by the
  /// package that owns its types, which depends on this one, so a parser here
  /// would invert the dependency direction. The raw map is retained so the
  /// owning package can parse it, and so two configs differing only in an
  /// unparsed section do not compare equal.
  ///
  /// A host declares which sections it composed a parser for through
  /// [assertSectionsHandled].
  final Map<String, Map<String, dynamic>> sections;

  /// Creates harness-level runtime controls.
  const new({this.sections = const {}});

  /// Default harness controls.
  const new defaults() : this();

  /// Throws a [StateError] naming every populated `harness.<name>` section
  /// outside [handled].
  ///
  /// This package retains an unclaimed section as data and cannot tell whether
  /// the host meant to compose a parser for it, so the host declares what it
  /// composed and a section nothing claims fails the load instead of being
  /// dropped silently. It is a composition contract, not an automatic check:
  /// an embedder that hand-rolls its own load path and never calls this gets
  /// no refusal.
  void assertSectionsHandled(Set<String> handled) {
    final unclaimed = sections.keys.where((section) => !handled.contains(section)).toList()..sort();
    if (unclaimed.isEmpty) return;
    throw StateError(
      'No parser was composed for ${unclaimed.map((section) => 'harness.$section').join(', ')}. '
      'Compose the package that owns the section, or remove it from the configuration — this deployment would '
      'otherwise run with it silently dropped.',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HarnessConfig && const DeepCollectionEquality().equals(sections, other.sections);

  @override
  int get hashCode => const DeepCollectionEquality().hash(sections);

  @override
  String toString() => 'HarnessConfig(sections: $sections)';
}

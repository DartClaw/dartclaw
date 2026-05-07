import 'package:dartclaw_models/dartclaw_models.dart' show SkillInfo;

/// Provider-specific resolution of an authored workflow skill reference.
final class ResolvedSkillRef {
  /// Authored canonical reference from workflow YAML.
  final String canonicalRef;

  /// Effective provider id used for alias resolution.
  final String provider;

  /// Provider-native skill name passed to harness activation.
  final String invocationName;

  /// Concrete discovered skill metadata matched by [invocationName].
  final SkillInfo skill;

  const ResolvedSkillRef({
    required this.canonicalRef,
    required this.provider,
    required this.invocationName,
    required this.skill,
  });
}

/// Registry of discovered Agent Skills-compatible skill definitions.
///
/// Provides skill lookup and validation for workflow step integration.
/// Interface defined in `dartclaw_core`; implementation in `dartclaw_server`.
abstract class SkillRegistry {
  /// All discovered skills with metadata.
  List<SkillInfo> listAll();

  /// Lookup by name (exact match).
  SkillInfo? getByName(String name);

  /// Resolve an authored skill reference for an effective provider.
  ResolvedSkillRef? resolveRef(String skillRef, String provider);

  /// Validate that a skill reference is resolvable.
  ///
  /// Returns null if valid, or an error message with suggestions.
  String? validateRef(String skillRef, {String? provider});

  /// Check if skill is natively available for the given harness type.
  bool isNativeFor(String skillName, String harnessType);
}

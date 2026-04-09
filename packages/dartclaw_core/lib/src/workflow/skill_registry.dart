import 'package:dartclaw_models/dartclaw_models.dart' show SkillInfo;

/// Registry of discovered Agent Skills-compatible skill definitions.
///
/// Provides skill lookup and validation for workflow step integration.
/// Interface defined in `dartclaw_core`; implementation in `dartclaw_server`.
abstract class SkillRegistry {
  /// All discovered skills with metadata.
  List<SkillInfo> listAll();

  /// Lookup by name (exact match).
  SkillInfo? getByName(String name);

  /// Validate that a skill reference is resolvable.
  ///
  /// Returns null if valid, or an error message with suggestions.
  String? validateRef(String skillRef);

  /// Check if skill is natively available for the given harness type.
  bool isNativeFor(String skillName, String harnessType);
}

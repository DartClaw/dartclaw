import 'package:dartclaw_workflow/dartclaw_workflow.dart';

/// In-memory [SkillIntrospector] fake with call tracking.
///
/// [listAvailable] returns the skills configured for the requested provider in
/// [skillsByProvider] (empty when the provider is absent) and records each
/// invocation in [calls] plus the per-provider options in
/// [providerOptionsByProvider].
final class FakeSkillIntrospector implements SkillIntrospector {
  final Map<String, Set<String>> skillsByProvider;

  /// Provider/executable pairs captured per [listAvailable] call, in order.
  final calls = <({String provider, String? executable})>[];

  /// Latest provider options observed per provider.
  final providerOptionsByProvider = <String, Map<String, dynamic>>{};

  FakeSkillIntrospector(this.skillsByProvider);

  @override
  Future<Set<String>> listAvailable({
    required String provider,
    String? executable,
    Map<String, dynamic> providerOptions = const <String, dynamic>{},
  }) async {
    calls.add((provider: provider, executable: executable));
    providerOptionsByProvider[provider] = providerOptions;
    return skillsByProvider[provider] ?? const <String>{};
  }
}

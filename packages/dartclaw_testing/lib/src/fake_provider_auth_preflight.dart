import 'package:dartclaw_workflow/dartclaw_workflow.dart';

/// In-memory [ProviderAuthPreflight] fake with call tracking.
///
/// Treats every provider as authenticated unless it is listed in
/// [unauthenticated], in which case [evaluate] returns an unauthenticated result
/// carrying an actionable remediation message. Each probed provider is recorded
/// in [probed], in order.
final class FakeProviderAuthPreflight implements ProviderAuthPreflight {
  final Set<String> unauthenticated;

  /// Providers passed to [evaluate], in order.
  final probed = <String>[];

  FakeProviderAuthPreflight({Set<String> unauthenticated = const <String>{}}) : unauthenticated = unauthenticated;

  @override
  Future<ProviderAuthResult> evaluate({
    required String provider,
    String? executable,
    Map<String, dynamic> providerOptions = const <String, dynamic>{},
  }) async {
    probed.add(provider);
    if (unauthenticated.contains(provider)) {
      return ProviderAuthResult.unauthenticated(
        provider,
        'Workflow provider "$provider" is not authenticated: run `$provider login`.',
      );
    }
    return ProviderAuthResult.authenticated(provider);
  }
}

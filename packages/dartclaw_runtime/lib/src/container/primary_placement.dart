import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../execution_policy_resolver.dart';

/// Whether [providerId]'s primary placement under [config] is a container.
///
/// The profile ids are the ones container wiring registers; the resolver is
/// built here, before `HarnessWiring` has one. A placement with no host
/// equivalent counts as host, as `HarnessWiring` reads it: that case is refused
/// at authority registration, and credential-wise it is the host.
bool primaryRunsInContainer(DartclawConfig config, String providerId) {
  final resolver = ExecutionPolicyResolver(
    config: config,
    availableContainerProfiles: config.container.enabled ? containerSecurityProfiles : const {},
  );
  try {
    return resolver.resolveForPrimary(providerId: providerId).isContainer;
  } on ExecutionPolicyException {
    return false;
  }
}

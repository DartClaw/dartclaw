import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'harness_factory.dart';

/// One registrar's contribution to the runtime's provider execution surface.
///
/// Registration of the harnesses themselves goes through
/// [HarnessFactory.registerFirstClaim] so the first registrar claim also owns the
/// factory; this type carries only the four contributions the
/// factory cannot express, each read by a different part of the runtime.
class HarnessRegistration {
  /// The providers this registration owns, layered over `config.providers`.
  ///
  /// The keys are the owned provider IDs the runtime feeds to its provider
  /// execution inventory; the values supply executable resolution and effective
  /// pool size. Executable and pool size replace the configured entry's;
  /// options are merged over its own, so a configured `providers.<id>` entry
  /// keeps its `auth` and its unrelated options.
  ///
  /// **The first registrar to claim a provider id owns it**, and that one rule
  /// decides all three lookups on this type. A later registration naming the
  /// same id is ignored rather than overwriting — resolving entries one way and
  /// the credential overlay the other would present one registration's binary
  /// under another's credential isolation.
  final Map<String, ProviderEntry> providerEntries;

  /// The declared container profile for [providerId], or `null` when this
  /// registration does not own it or declares none.
  ///
  /// A function rather than a map because the runtime resolves fail-closed
  /// placement warnings before the effective provider entries exist — a
  /// snapshot taken at [HarnessRegistrar.declare] time would be read before it
  /// was populated and placement would silently degrade to the neutral profile.
  final String? Function(String providerId)? containerProfileFor;

  /// The spawn environment for [providerId], replacing the runtime's own
  /// first-party credential overlay, or `null` when this registration does not
  /// own the provider.
  final Map<String, String> Function(String providerId, Map<String, String> environment)? credentialOverlayFor;

  /// Diagnostics emitted through the runtime's single deduplicating startup
  /// warning sink, interleaved with the runtime's own.
  final List<String> warnings;

  /// Diagnostics emitted only when this deployment configures agent or job tool
  /// policy.
  ///
  /// Whether tool policy is configured is the runtime's own reading of
  /// `agent.*`, `memory.*` and `knowledge.*`; what a provider family cannot
  /// enforce under it is the registrar's. Neither side can answer alone, so the
  /// registrar supplies the sentence and the runtime supplies the condition and
  /// the position in the startup sequence.
  final List<String> toolPolicyWarnings;

  const new({
    this.providerEntries = const {},
    this.containerProfileFor,
    this.credentialOverlayFor,
    this.warnings = const [],
    this.toolPolicyWarnings = const [],
  });
}

/// Contributes harness providers the runtime does not name itself.
///
/// A registrar reaches the runtime only by being passed to
/// `DartclawRuntime.build(harnessRegistrars:)`; there is no discovery, lookup or
/// import-time registration. Registrars are invoked in list order.
///
/// Either member may throw to abort assembly fail-closed: a [declare] throw
/// stops the runtime before it resolves execution placement, an [activate]
/// throw before any worker is spawned.
abstract interface class HarnessRegistrar {
  /// Declares this registrar's contribution from parsed config alone.
  ///
  /// Synchronous and I/O-free: it runs before the runtime resolves execution
  /// placement or builds its provider inventory, both of which read the result.
  HarnessRegistration declare(DartclawConfig config);

  /// Parses the `harness.<name>` sections this registrar owns into [config]'s
  /// own load-warning sink.
  ///
  /// Called for every config a runtime is asked to adopt, including a reload's,
  /// before the reload is judged admissible — a section parsed outside
  /// `dartclaw_kernel` carries no warnings until something parses it, and an
  /// unparseable registration must refuse a reload exactly as it did when the
  /// parse lived inside `DartclawConfig.load`. Must be idempotent per config
  /// instance: it is also called from the host's own production load path.
  void primeConfigSections(DartclawConfig config);

  /// Registers this registrar's harnesses on [factory] and returns the
  /// refinement of its [declare] result.
  ///
  /// Runs after the runtime's startup diagnostics and before the effective
  /// worker provider entries are computed, so it may probe.
  Future<HarnessRegistration> activate(DartclawConfig config, HarnessFactory factory);
}

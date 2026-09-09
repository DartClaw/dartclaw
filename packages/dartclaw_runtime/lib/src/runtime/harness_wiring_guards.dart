part of 'harness_wiring.dart';

/// Creates a per-runner [GuardChain] layering the runner's [filter] after all
/// guards of [base].
///
/// Each runner (primary and worker) requires its own chain so that mutating
/// [filter] policies for one runner does not affect others. The base guard
/// list is tracked live: a guards.* hot-reload ([GuardChain.replaceGuards] on
/// [base]) reaches every runner chain while the filter survives the rebuild.
/// When [base] is null, configured tool policy remains active independently of
/// the optional security-guard bundle.
GuardChain _buildRunnerGuardChain(GuardChain? base, TaskToolFilterGuard filter, ToolPolicyCascade cascade) =>
    GuardChain.layered(
      base: base,
      guards: [
        if (base == null) ToolPolicyGuard(cascade: cascade),
        filter,
      ],
    );

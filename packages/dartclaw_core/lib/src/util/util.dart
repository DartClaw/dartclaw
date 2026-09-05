/// Shared runtime utility primitives for `dartclaw_core` consumers.
///
/// Re-exported as a single entry from the package barrel to keep the top-level
/// public surface compact (one sub-barrel export instead of one per util).
library;

export 'datetime_format.dart' show formatLocalDateTime, tryParseIsoInstant;
export 'frontmatter.dart' show splitFrontmatter;
export 'duration_format.dart' show humanizeDuration, humanizeDurationMs, humanizeSpan;

// Owned by `dartclaw_kernel` so the tier below core can use it too; re-exported
// here because core's own callers and the packages above it already reach it
// through this barrel.
export 'package:dartclaw_kernel/dartclaw_kernel.dart' show HttpClientFactory, httpRequest;

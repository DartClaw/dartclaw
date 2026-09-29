import 'package:dartclaw_core/dartclaw_core.dart';

/// Persists telemetry observed by a real harness turn through the owning
/// conversation mutation authority.
typedef RuntimeContextTelemetryObserved = Future<void> Function(SessionContextTelemetry telemetry);

import 'package:dartclaw_core/dartclaw_core.dart' show SessionService;
import 'package:dartclaw_server/src/execution_coordinator.dart';
import 'package:dartclaw_server/src/turn_manager.dart';
import 'package:dartclaw_server/src/turn_runner.dart';

ExecutionCoordinator coordinatorForRunners(List<TurnRunner> runners, {Map<String, int>? providerCapacities}) {
  if (runners.isEmpty) throw ArgumentError.value(runners, 'runners', 'must include a primary runner');
  final available = List<TurnRunner>.from(runners.skip(1));
  final capacities = providerCapacities ?? <String, int>{};
  if (providerCapacities == null) {
    for (final runner in available) {
      capacities.update(runner.providerId, (count) => count + 1, ifAbsent: () => 1);
    }
  }
  return ExecutionCoordinator(
    providerCapacities: capacities,
    primary: runners.first,
    allowPrimaryBackgroundFallback: available.isEmpty,
    admitExecution: (request) => runners.first.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
    releaseAdmission: runners.first.releaseAdmission,
    createWorker: (request) async {
      final index = available.indexWhere(
        (runner) => runner.providerId == request.providerId && runner.profileId == request.profileId,
      );
      if (index < 0) {
        throw StateError('No test runner for ${request.providerId}/${request.profileId}');
      }
      return available.removeAt(index);
    },
  );
}

TurnManager turnManagerForRunners(
  List<TurnRunner> runners, {
  SessionService? sessions,
  Map<String, int>? providerCapacities,
}) => TurnManager.fromCoordinator(
  coordinator: coordinatorForRunners(runners, providerCapacities: providerCapacities),
  sessions: sessions,
);

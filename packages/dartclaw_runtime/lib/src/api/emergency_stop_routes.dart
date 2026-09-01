import 'package:dartclaw_core/dartclaw_core.dart' show EventBus, TurnManager;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/request_auth_context.dart';
import '../emergency/emergency_stop_handler.dart';
import '../task/task_service.dart';
import 'api_helpers.dart';
import 'sse_broadcast.dart';

/// Registers the channel-free emergency stop entry point on [router].
///
/// `POST /api/emergency-stop` (operator/admin only) runs the same sequence a
/// channel `/stop` runs, so an install with every channel disabled still has a
/// way to stop every turn and task in flight.
void registerEmergencyStopRoutes(
  Router router, {
  required TurnManager Function() turnManagerGetter,
  required TaskService taskService,
  required EventBus eventBus,
  required SseBroadcast sseBroadcast,
}) {
  router.post('/api/emergency-stop', (Request request) async {
    if (!requestHasAdminAccess(request)) {
      return errorResponse(403, 'EMERGENCY_STOP_FORBIDDEN', 'Emergency stop requires operator/admin access');
    }
    final result = await EmergencyStopHandler(
      turnManager: turnManagerGetter(),
      taskService: taskService,
      eventBus: eventBus,
      sseBroadcast: sseBroadcast,
    ).execute(stoppedBy: _callerOf(request));
    return jsonResponse(200, {'turnsCancelled': result.turnsCancelled, 'tasksCancelled': result.tasksCancelled});
  });
}

/// The audited caller, derived from how the request authenticated rather than
/// from anything it declares about itself.
String _callerOf(Request request) => requestIsLocalAdmin(request)
    ? 'local admin'
    : requestIsCookieAuthenticated(request)
    ? 'web session'
    : 'api token';

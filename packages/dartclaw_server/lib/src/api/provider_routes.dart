import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../provider_status_service.dart';
import 'api_helpers.dart';

Router providerRoutes({required ProviderStatusService providerStatus}) {
  final router = Router();

  router.get('/api/providers', (Request request) {
    return jsonResponse(200, {
      'providers': providerStatus.getAll().map((provider) => provider.toJson()).toList(growable: false),
      'summary': providerStatus.getSummary(),
    });
  });

  return router;
}

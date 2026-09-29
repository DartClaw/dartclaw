import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show ModelCatalogue;
import 'package:logging/logging.dart';

/// The one runtime owner of provider-reported model catalogues.
///
/// [start] discovers every provider in the background; views read the result
/// through [catalogueFor] and never wait on it. A catalogue that arrived is
/// kept for the life of the process. A provider whose discovery failed is
/// discovered again by the first read at least [retryAfter] after its last
/// attempt, one attempt at a time.
class ModelCatalogueDiscovery {
  /// Spacing between attempts for a provider whose discovery failed.
  static const retryAfter = Duration(minutes: 5);

  static final _log = Logger('ModelCatalogueDiscovery');

  final Set<String> _providers;
  final Future<ModelCatalogue> Function(String providerId) _discover;
  final DateTime Function() _now;
  final Map<String, ModelCatalogue> _catalogues = {};
  final Map<String, DateTime> _failedAt = {};
  final Set<String> _inFlight = {};

  new({
    required Iterable<String> providers,
    required Future<ModelCatalogue> Function(String providerId) discover,
    DateTime Function()? now,
  }) : _providers = Set.unmodifiable(providers),
       _discover = discover,
       _now = now ?? DateTime.now;

  /// Starts discovery for every provider not yet attempted; a failed one waits
  /// for [catalogueFor]'s retry.
  void start() {
    for (final providerId in _providers) {
      if (!_catalogues.containsKey(providerId) && !_failedAt.containsKey(providerId)) _attempt(providerId);
    }
  }

  /// The catalogue [providerId] reported, or `null` before or without one.
  ModelCatalogue? catalogueFor(String providerId) {
    final catalogue = _catalogues[providerId];
    if (catalogue != null) return catalogue;
    final failedAt = _failedAt[providerId];
    if (failedAt != null && !_now().isBefore(failedAt.add(retryAfter))) _attempt(providerId);
    return null;
  }

  void _attempt(String providerId) {
    if (!_providers.contains(providerId) || !_inFlight.add(providerId)) return;
    unawaited(
      Future.sync(() => _discover(providerId))
          .then(
            (catalogue) {
              _catalogues[providerId] = catalogue;
              _failedAt.remove(providerId);
              _log.info('Model catalogue for provider "$providerId": ${catalogue.entries.length} model(s)');
            },
            onError: (Object error, StackTrace stackTrace) {
              _failedAt[providerId] = _now();
              _log.warning('Model catalogue discovery failed for provider "$providerId"', error, stackTrace);
            },
          )
          .whenComplete(() => _inFlight.remove(providerId)),
    );
  }
}

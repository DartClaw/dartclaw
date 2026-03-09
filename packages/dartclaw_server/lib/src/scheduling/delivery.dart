import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

/// How a scheduled job's output is delivered after execution.
enum DeliveryMode { announce, webhook, none }

final _log = Logger('Delivery');

/// Delivers job results according to the delivery mode.
Future<void> deliverResult({
  required DeliveryMode mode,
  required String jobId,
  required String result,
  String? webhookUrl,
}) async {
  switch (mode) {
    case DeliveryMode.none:
      return;
    case DeliveryMode.announce:
      _log.info('Job $jobId result ready for channel delivery (announce stub): ${result.length} chars');
      return;
    case DeliveryMode.webhook:
      if (webhookUrl == null || webhookUrl.isEmpty) {
        _log.severe('Job $jobId: webhook delivery configured but no webhook_url');
        return;
      }
      await _postWebhook(jobId, result, webhookUrl);
  }
}

Future<void> _postWebhook(String jobId, String result, String url) async {
  final client = HttpClient();
  try {
    client.connectionTimeout = const Duration(seconds: 10);
    final request = await client.postUrl(Uri.parse(url));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'job_id': jobId,
      'result': result,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    }));
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      _log.info('Job $jobId: webhook delivered to $url (${response.statusCode})');
    } else {
      _log.severe('Job $jobId: webhook to $url returned ${response.statusCode}');
    }
    await response.drain<void>();
  } catch (e) {
    _log.severe('Job $jobId: webhook delivery to $url failed: $e');
  } finally {
    client.close();
  }
}

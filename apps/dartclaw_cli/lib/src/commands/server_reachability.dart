import 'dart:async';
import 'dart:io';

Future<bool> serverReachable(Uri baseUri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    return await (() async {
      final directory = baseUri.path.endsWith('/') ? baseUri : baseUri.replace(path: '${baseUri.path}/');
      final request = await client.getUrl(directory.resolve('health'));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == 200 || response.statusCode == 401 || response.statusCode == 403;
    })().timeout(const Duration(seconds: 5));
  } on IOException {
    return false;
  } on TimeoutException {
    return false;
  } finally {
    client.close(force: true);
  }
}

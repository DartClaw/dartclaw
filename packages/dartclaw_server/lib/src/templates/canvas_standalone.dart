import 'loader.dart';

/// Renders the public share-token canvas page.
String canvasStandaloneTemplate({
  required String token,
  required String permission,
  required String streamUrl,
  required String actionUrl,
  required String nonce,
}) {
  final isInteract = permission == 'interact';
  final isViewOnly = !isInteract;
  return templateLoader.trellis.render(templateLoader.source('canvas_standalone'), {
    'token': token,
    'permission': permission,
    'streamUrl': streamUrl,
    'actionUrl': actionUrl,
    'nonce': nonce,
    'isInteract': isInteract,
    'isViewOnly': isViewOnly,
  });
}

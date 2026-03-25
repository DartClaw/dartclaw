import 'loader.dart';

/// Renders the sandboxed admin iframe canvas page.
String canvasEmbedTemplate({required String sessionKey, required String streamUrl, required String nonce}) {
  return templateLoader.trellis.render(templateLoader.source('canvas_embed'), {
    'sessionKey': sessionKey,
    'streamUrl': streamUrl,
    'nonce': nonce,
  });
}

import 'loader.dart';

/// Renders the restart-required banner.
///
/// [pendingFields] is the list of human-readable field names that changed.
///
/// The node is always emitted, so the shell's restart slot holds one stable
/// `#restart-banner` element that client state can reveal and re-hide without
/// creating or destroying markup. An empty [pendingFields] renders it `hidden`
/// and `inert` with an empty field list; a non-empty one renders it visible.
String restartBannerTemplate({required List<String> pendingFields}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('restart_banner'),
    fragment: 'restartBanner',
    // Emitted as a nullable string rather than a bool: Trellis drops a null
    // attribute outright, whereas `inert="false"` would still be inert in HTML.
    context: {'fieldList': pendingFields.join(', '), 'dormant': pendingFields.isEmpty ? '' : null},
  );
}

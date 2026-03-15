import 'loader.dart';

/// Renders the restart-required banner.
///
/// [pendingFields] is the list of human-readable field names that changed.
/// Returns empty string if [pendingFields] is empty.
String restartBannerTemplate({required List<String> pendingFields}) {
  if (pendingFields.isEmpty) return '';
  return templateLoader.trellis.renderFragment(
    templateLoader.source('restart_banner'),
    fragment: 'restartBanner',
    context: {'fieldList': pendingFields.join(', ')},
  );
}

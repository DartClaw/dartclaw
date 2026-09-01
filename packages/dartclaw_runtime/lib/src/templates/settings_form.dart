import 'loader.dart';

/// Renders one settings section as the swappable form fragment.
///
/// The returned `<form>` is the HTMX target for its own `POST /settings`, so
/// the same call serves the page render and every re-render after a save.
String settingsSectionFragment(Map<String, Object?> view, {String action = '/settings'}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('settings_form'),
    fragment: 'settingsSection',
    context: {...view, 'action': action},
  );
}

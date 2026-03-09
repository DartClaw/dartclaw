import 'layout.dart';
import 'loader.dart';

/// Login page template with token input form.
///
/// [error] is shown as an error message when non-null (e.g. "Invalid token").
/// [appName] is the configurable instance name shown in the logo and title.
String loginPageTemplate({String? error, String appName = 'DartClaw'}) {
  final body = templateLoader.trellis.render(
    templateLoader.source('login'),
    {'error': error, 'appName': appName},
  );
  return layoutTemplate(title: 'Login', body: body, appName: appName);
}

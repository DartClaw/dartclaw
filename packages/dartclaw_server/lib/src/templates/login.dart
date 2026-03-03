import 'layout.dart';
import 'loader.dart';

/// Login page template with token input form.
///
/// [error] is shown as an error message when non-null (e.g. "Invalid token").
String loginPageTemplate({String? error}) {
  final body = templateLoader.trellis.render(
    templateLoader.source('login'),
    {'error': error},
  );
  return layoutTemplate(title: 'Login', body: body);
}

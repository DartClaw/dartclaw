import 'layout.dart';
import 'loader.dart';

/// Renders a full styled error page with design tokens.
String errorPageTemplate(int code, String title, String detail, {String appName = 'DartClaw'}) {
  final body = templateLoader.trellis.render(templateLoader.source('error_page'), {
    'code': code,
    'title': title,
    'detail': detail,
  });
  return layoutTemplate(title: '$code $title', body: body, appName: appName);
}

import 'helpers.dart';
import 'layout.dart';

/// Renders a full styled error page with design tokens.
String errorPageTemplate(int code, String title, String detail) {
  final body =
      '<div class="error-page">'
      '<div class="error-code">$code</div>'
      '<div class="error-title">${htmlEscape(title)}</div>'
      '<div class="error-detail">${htmlEscape(detail)}</div>'
      '<a href="/" class="btn btn-primary">&#8592; Back to Home</a>'
      '</div>';
  return layoutTemplate(title: '$code $title', body: body);
}

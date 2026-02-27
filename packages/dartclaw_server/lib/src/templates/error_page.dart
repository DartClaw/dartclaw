import 'helpers.dart';
import 'layout.dart';

/// Renders a full styled error page with design tokens.
String errorPageTemplate(int code, String title, String detail) {
  final body =
      '<style>'
      '.error-page{display:flex;flex-direction:column;align-items:center;justify-content:center;'
      'min-height:100vh;gap:var(--sp-4);padding:var(--sp-8);text-align:center;}'
      '.error-code{font-size:4rem;font-weight:var(--weight-bold);color:var(--fg-overlay);line-height:1;}'
      '.error-title{font-size:var(--text-xl);font-weight:var(--weight-bold);color:var(--fg);}'
      '.error-detail{font-size:var(--text-sm);color:var(--fg-sub0);max-width:480px;}'
      '</style>'
      '<div class="error-page">'
      '<div class="error-code">$code</div>'
      '<div class="error-title">${htmlEscape(title)}</div>'
      '<div class="error-detail">${htmlEscape(detail)}</div>'
      '<a href="/" class="btn btn-primary">&#8592; Back to Home</a>'
      '</div>';
  return layoutTemplate(title: '$code $title', body: body);
}

import 'helpers.dart';
import 'layout.dart';

/// Login page template with token input form.
///
/// [error] is shown as an error message when non-null (e.g. "Invalid token").
String loginPageTemplate({String? error}) {
  final errorHtml = error != null
      ? '<div class="login-error">${htmlEscape(error)}</div>'
      : '';

  final body = '''
<div class="login-container">
  <div class="login-card">
    <div class="login-header">
      <div class="logo">&#10095; DartClaw</div>
      <p class="login-subtitle">Enter your gateway token to continue</p>
    </div>
    $errorHtml
    <form method="POST" action="/login" class="login-form">
      <div class="login-field">
        <label for="token-input" class="login-label">Gateway Token</label>
        <input id="token-input" name="token" type="password" placeholder="Paste your token here"
               autocomplete="off" autofocus required
               class="login-input">
      </div>
      <label class="login-checkbox">
        <input type="checkbox" name="remember" value="1">
        Remember this device
      </label>
      <button type="submit" class="btn btn-primary btn-login">Sign In &#10095;</button>
    </form>
    <div class="login-footer">
      Token printed at server startup, or run<br>
      <code>dartclaw token show</code>
    </div>
  </div>
</div>
''';

  return layoutTemplate(title: 'Login', body: body);
}

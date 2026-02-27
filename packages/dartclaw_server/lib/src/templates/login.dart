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
<style>
.login-container {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100vh;
  padding: var(--sp-4);
}
.login-card {
  width: 100%;
  max-width: 380px;
  background: var(--bg-mantle);
  border: var(--border);
  border-radius: var(--radius-lg);
  padding: var(--sp-8);
  box-shadow: var(--shadow-md);
  display: flex;
  flex-direction: column;
  gap: var(--sp-5);
}
.login-header { text-align: center; }
.login-header .logo {
  font-size: var(--text-xl);
  font-weight: var(--weight-bold);
  color: var(--accent);
  margin-bottom: var(--sp-2);
}
.login-subtitle {
  font-size: var(--text-sm);
  color: var(--fg-overlay);
}
.login-error {
  background: color-mix(in srgb, var(--error) 12%, var(--bg-base));
  border: 1px solid var(--error);
  color: var(--error);
  padding: var(--sp-2) var(--sp-3);
  border-radius: var(--radius);
  font-size: var(--text-sm);
}
.login-form {
  display: flex;
  flex-direction: column;
  gap: var(--sp-3);
}
.login-field { display: flex; flex-direction: column; gap: var(--sp-1); }
.login-label {
  font-size: var(--text-xs);
  font-weight: var(--weight-medium);
  color: var(--fg-sub0);
  text-transform: uppercase;
  letter-spacing: 0.06em;
}
.login-input {
  padding: var(--sp-2) var(--sp-3);
  background: var(--bg-base);
  border: var(--border);
  border-radius: var(--radius);
  color: var(--fg);
  font-family: var(--font-mono);
  font-size: var(--text-base);
  width: 100%;
  transition: border-color var(--transition);
}
.login-input:focus {
  outline: none;
  border-color: var(--accent);
}
.login-checkbox {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  font-size: var(--text-sm);
  color: var(--fg-sub0);
  cursor: pointer;
  user-select: none;
}
.login-checkbox input[type="checkbox"] {
  accent-color: var(--accent);
  width: 14px;
  height: 14px;
  cursor: pointer;
}
.btn-login {
  width: 100%;
  justify-content: center;
  padding: var(--sp-2) var(--sp-4);
  font-size: var(--text-base);
}
.login-footer {
  text-align: center;
  font-size: var(--text-xs);
  color: var(--fg-overlay);
  border-top: var(--border);
  padding-top: var(--sp-4);
  line-height: var(--leading);
}
.login-footer code {
  background: var(--bg-base);
  padding: 0 var(--sp-1);
  border-radius: 2px;
  font-size: var(--text-xs);
  color: var(--fg-sub1);
}
</style>
''';

  return layoutTemplate(title: 'Login', body: body);
}

/// Shell-escapes [value] for safe use as a single argument inside a shell
/// command string.
///
/// Used to sanitize `{{context.*}}` substitution values before they are passed
/// to `Process.run()` via the shell (`/bin/sh -c`).
///
/// All context values are wrapped in single-quotes with internal single-quotes
/// escaped as `'\''`. This prevents injection via spaces, dollar signs,
/// semicolons, backticks, glob characters, and command substitution syntax.
///
/// The result is always single-quote wrapped, so it can be embedded verbatim in
/// a `sh -c` invocation:
///
/// ```dart
/// final cmd = 'git log ${shellEscape(branch)}';
/// ```
String shellEscape(String value) {
  // Replace every ' with '\'' (end quote, escaped quote, start quote).
  final escaped = value.replaceAll("'", "'\\''");
  return "'$escaped'";
}

/// Generates a macOS LaunchDaemon plist for DartClaw.
///
/// Placeholders (`__ANTHROPIC_API_KEY__`) are replaced at the secrets step.
String generatePlist({
  required String binPath,
  required String host,
  required int port,
  required String dataDir,
  required String user,
}) => '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.dartclaw.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>$binPath</string>
    <string>serve</string>
    <string>--host</string>
    <string>$host</string>
    <string>--port</string>
    <string>$port</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ANTHROPIC_API_KEY</key>
    <string>__ANTHROPIC_API_KEY__</string>
  </dict>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$dataDir/logs/dartclaw.log</string>
  <key>StandardErrorPath</key>
  <string>$dataDir/logs/dartclaw.err.log</string>
  <key>UserName</key>
  <string>$user</string>
</dict>
</plist>
''';

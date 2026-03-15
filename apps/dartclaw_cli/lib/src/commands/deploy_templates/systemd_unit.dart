/// Generates a Linux systemd unit file for DartClaw.
///
/// Placeholders (`__ANTHROPIC_API_KEY__`) are replaced at the secrets step.
String generateUnit({
  required String binPath,
  required String host,
  required int port,
  required String dataDir,
  required String user,
}) =>
    '''[Unit]
Description=DartClaw Agent Runtime
After=network.target

[Service]
Type=simple
User=$user
ExecStart=$binPath serve --host $host --port $port
Environment=ANTHROPIC_API_KEY=__ANTHROPIC_API_KEY__
WorkingDirectory=$dataDir
Restart=always
RestartSec=5

StandardOutput=append:$dataDir/logs/dartclaw.log
StandardError=append:$dataDir/logs/dartclaw.err.log

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$dataDir
PrivateTmp=true

[Install]
WantedBy=multi-user.target
''';

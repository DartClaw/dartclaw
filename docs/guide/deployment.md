# Deployment

DartClaw is designed for always-on deployment on a Mac Mini or Linux server.

## Quick Deploy

```bash
# 1. Setup (create directories, plist/systemd unit)
dartclaw deploy setup

# 2. Configure (generate dartclaw.yaml from wizard)
dartclaw deploy config

# 3. Secrets (set ANTHROPIC_API_KEY securely)
dartclaw deploy secrets
```

## AOT Compilation

Compile DartClaw to a native binary for production:

```bash
dart compile exe apps/dartclaw_cli/bin/dartclaw.dart -o dartclaw
```

The resulting binary has zero runtime dependencies (no Dart SDK needed).

## macOS (LaunchDaemon)

`dartclaw deploy setup` creates a LaunchDaemon plist at `/Library/LaunchDaemons/com.dartclaw.agent.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.dartclaw.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/dartclaw</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>UserName</key><string>dartclaw</string>
</dict>
</plist>
```

## Linux (systemd)

`dartclaw deploy setup` creates a systemd unit at `/etc/systemd/system/dartclaw.service`:

```ini
[Unit]
Description=DartClaw Agent Runtime
After=network.target docker.service

[Service]
Type=simple
User=dartclaw
ExecStart=/usr/local/bin/dartclaw serve
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## Dedicated User

Create a dedicated OS user for isolation:

```bash
# macOS
sudo dscl . -create /Users/dartclaw
# Linux
sudo useradd -r -s /bin/false dartclaw
```

## Egress Firewall

Restrict outbound network access to only required services:

### macOS (pf)
```
# /etc/pf.anchors/dartclaw
pass out proto tcp from any to any port 443   # Anthropic API
block out quick user dartclaw
```

### Linux (nftables)
```
table inet dartclaw {
  chain output {
    type filter hook output priority 0;
    meta skuid dartclaw tcp dport 443 accept
    meta skuid dartclaw drop
  }
}
```

## Health Monitoring

Check agent health:

```bash
curl http://localhost:3000/health
```

Returns JSON with worker state, uptime, and session counts.

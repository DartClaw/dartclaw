# Customization Ladder

DartClaw offers five levels of customization, from zero-code to full source modification.

## L1: Behavior Files (No Code)

Edit markdown files in `~/.dartclaw/workspace/`. Changes take effect on the next turn.

| File | What to customize |
|------|------------------|
| `SOUL.md` | Agent personality, expertise, communication style |
| `AGENTS.md` | Safety rules and operational boundaries |
| `USER.md` | Your name, timezone, preferences |
| `TOOLS.md` | Environment notes (servers, endpoints, credentials reference) |
| `HEARTBEAT.md` | Periodic tasks the agent should perform |

**Example**: Make the agent a Dart expert:
```markdown
# SOUL.md
You are an expert Dart and Flutter developer. You prefer:
- Immutable data classes with factory constructors
- Extension methods over utility classes
- shelf for HTTP, not dart_frog
- Minimal dependencies
```

## L2: Config YAML (No Code)

Edit `dartclaw.yaml` to tune runtime behavior without touching source code.

**Example**: Restrict the agent and enable WhatsApp:
```yaml
guards:
  command:
    blocked_commands: [rm, shutdown, curl]
  filesystem:
    blocked_paths: [.ssh, .aws, /etc]

channels:
  whatsapp:
    enabled: true
    dm_access: pairing

scheduling:
  heartbeat:
    interval_minutes: 15
```

## L3: Skills (No Code)

Create reusable prompt templates in `.claude/skills/`. Skills are prompt fragments the agent can invoke.

**Example**: `.claude/skills/code-review.md`
```markdown
Review this code for:
1. Security vulnerabilities (OWASP top 10)
2. Performance issues
3. Dart idiom violations
4. Missing error handling
Provide specific line references.
```

## L4: MCP Servers (Minimal Code)

Add external tool integrations via `.mcp.json`. MCP servers expose tools to the agent.

**Example**: `.mcp.json`
```json
{
  "servers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"]
    },
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/projects"]
    }
  }
}
```

## L5: Code (Dart Source)

Extend DartClaw's Dart source for deep customization:

- **Custom Guards**: Implement the `Guard` abstract class for domain-specific security rules
- **Custom Channels**: Implement the `Channel` abstract class for new messaging platforms
- **Template Overrides**: Modify HTML template functions in `dartclaw_server`
- **Custom MCP Tools**: Implement the `McpTool` interface and register via `server.registerTool()`

**Example**: Custom guard that blocks after business hours:
```dart
class BusinessHoursGuard extends Guard {
  @override String get name => 'business-hours';
  @override String get category => 'scheduling';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    final hour = DateTime.now().hour;
    if (hour < 9 || hour > 17) {
      return GuardVerdict.block('Outside business hours');
    }
    return GuardVerdict.pass();
  }
}
```

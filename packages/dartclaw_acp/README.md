# dartclaw_acp

Agent Client Protocol (ACP) support for the DartClaw agent runtime — the
`AcpHarness` and its stdio JSON-RPC client, the protocol adapter, the
reverse-call handlers, target validation, the `harness.acp.*` config section,
and the `HarnessRegistrar` that composes all of it into a runtime.

ACP agents are third-party binaries. DartClaw drives them over stdio JSON-RPC,
mediates their reverse calls through the guard chain, and presents them only
the API key their own registration names — never a DartClaw-managed provider
credential.

> **Status: Pre-1.0**. The ACP contract is experimental and may change.

## Installation

```yaml
dependencies:
  dartclaw_acp:
    path: ../dartclaw_acp
```

## Composing it

The runtime never names this package. A host that wants ACP passes the
registrar when it builds the runtime, and primes the config section on every
production load:

```dart
final config = loadCliConfig(configPath: path);
acpConfigFor(config);
config.harness.assertSectionsHandled(const {'acp'});

final runtime = await DartclawRuntime.build(config, harnessRegistrars: [AcpHarnessRegistrar()]);
```

A host that composes no registrar parses no `harness.acp` section and registers
no ACP provider; `assertSectionsHandled` refuses a config carrying one rather
than dropping it silently.

## Deliberate postures

- **Host-only.** No ACP container combination has provider-credential or
  host-capability mediation, so a registration that requires a container
  boundary — `topology: relay`/`unverified`, or `container_isolation_required:
  true` — is refused at startup rather than landing on the host with the
  boundary discarded.
- **Credential isolation.** `harness.acp.agents.<id>.credential` names a
  `credentials.<name>` API-key entry and is the only credential an ACP agent is
  presented. `model_provider` selects none, and no subscription credential is
  ever forwarded.
- **Operator configuration is the only source of a container profile.** The
  registrar's declared profile *is* `harness.acp.agents.<id>.container_profile`;
  there is no code-declared default that could outrank it.

## License

MIT

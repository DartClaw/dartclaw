# Context Engine Mode

Context Engine retrieval is separate from a conversation's effective context. It selects sources from the authenticated
caller, returns citation-backed packets, and does not change any conversation's project, directory, provider, model,
effort, workspace binding, or storage principal.

Context-engine mode lets other tools — an IDE, a second agent, a scratch script — read your DartClaw knowledge surface
over MCP under their own name, without giving them your gateway token.

A named client can call exactly three read tools. It cannot write anything, cannot reach the web through DartClaw, and
cannot reach any DartClaw surface other than `/mcp`. Every call it makes, allowed or refused, is written to the guard
audit trail under that client's name.

DartClaw stays single-owner: one person owns the chat identity and every write. Context-engine mode is the one carved-out
exception, and it is read-only.

## Setup

Context-engine mode requires `gateway.auth_mode: token`. Each client's token is written as a `${VAR}` environment
reference — never a literal — and DartClaw refuses to start on a client list it cannot enforce.

```yaml
gateway:
  auth_mode: token
  token: ${DARTCLAW_GATEWAY_TOKEN}
  mcp_clients:
    - name: ide
      token: ${DARTCLAW_MCP_CLIENT_IDE}
    - name: research-bot
      token: ${DARTCLAW_MCP_CLIENT_RESEARCH}
```

Generate a token per client the way you would any secret, and export it before starting the server:

```bash
export DARTCLAW_MCP_CLIENT_IDE="$(openssl rand -hex 32)"
```

The client then talks to `POST /mcp` with `Authorization: Bearer $DARTCLAW_MCP_CLIENT_IDE`, using the same MCP
Streamable HTTP transport the owner uses.

DartClaw refuses to start when a client token is a literal value, when its `${VAR}` resolves to nothing, when two clients
share a token, when a client's token equals the gateway token, when a name is repeated, or when clients are configured
under `auth_mode: none`. Each message names the offending client. An unset variable is a startup error rather than a
warning on purpose: an empty token would otherwise match an empty or malformed bearer.

## What a client can call

| Tool | What it reads |
|---|---|
| `kg_query` | The temporal knowledge graph as of a point in time |
| `kg_timeline` | A single entity's fact history |
| `context_research` | A synthesized, cited answer over the shared wiki and knowledge graph |

Everything else answers as if it did not exist — same JSON-RPC error code, same message, whether the tool is a write
tool, a tool DartClaw registers but keeps out of the profile, or a name that was never registered. A client cannot use
the refusal to learn what a deployment has.

The profile is an allowlist, not "everything read-only". The web-search tools change nothing here and are classified
read, but they reach third parties on your credentials, so a client cannot call them — a read classification is not by
itself a reason to expose a tool. `web_fetch` is classified write and is excluded either way.

## What each caller sees

| Caller | Private source | Shared sources | Excluded sources |
|---|---|---|---|
| Owner/default conversation | Owner personal memory | Wiki and temporal knowledge graph | Named-agent memory, knowledge inbox |
| Named agent A | Agent A personal memory, when its tool policy grants `context_research` | Wiki and temporal knowledge graph | Owner memory, agent B memory, knowledge inbox |
| Named agent B | Agent B personal memory, when granted | Wiki and temporal knowledge graph | Owner memory, agent A memory, knowledge inbox |
| Named MCP client | None | Wiki and temporal knowledge graph | Every personal-memory corpus, knowledge inbox |

The wiki and knowledge graph are explicit publication surfaces. A named agent publishes there only through separately
granted write tools, and the knowledge-inbox job publishes accepted synthesized outputs only after validation. Raw inbox
files, rejected inputs, personal-memory provenance, and another principal's source locators are not research sources.
Direct KG reads and research citations describe published facts without exposing the original private `source` field.

Every configured client sees that same shared published surface. `kg_facts.owner` remains write authority rather than a
read ACL, so configure a client only for something you would let read the wiki and knowledge graph.

## Cost

`context_research` runs a real model turn, so an authorised client spends your model budget. This is intended — it is
the tool that makes the knowledge surface useful to another agent — but it means a client's reads are not free.

There are no per-client rate limits or token budgets. The deployment-wide
[`governance.budget.daily_tokens`](governance.md) cap is the only bound on what a client can spend, and it is shared
with your own turns. The per-sender governance limits gate inbound channel messages by channel peer, not MCP calls, so
they do not apply here.

## Audit

Every `tools/call` from a client is written to the guard audit trail with `principal: mcp-client:<name>`: permitted
reads by the MCP dispatch seam, refusals by the profile policy. Your own `/mcp` calls with the gateway token continue to
audit as the steward principal (`system`), because the gateway token authenticates the deployment rather than a person.

The audit records that a call was authorised and by whom. It is not a session-level or per-task restriction: MCP dispatch
is not a runner turn, so read-only session mode and per-task tool policy do not apply to the client surface. What bounds
a client is the profile plus the base guard chain.

## Revoking access

Remove the client's entry from `gateway.mcp_clients` and restart the server. The client list is read when `/mcp` is
mounted, exactly like `gateway.token`, so there is no live kill switch — a removed client keeps working until restart.

Rotating a client's token means changing the environment variable and restarting; the config file never holds the
secret, and neither the config API, the web UI, nor a log line ever renders it.

## See also

- [Security](security.md) — the guard chain, what MCP dispatch does and does not enforce
- [Configuration](configuration.md#gateway) — `gateway.mcp_clients` in the full field reference
- [Web UI & API](web-ui-and-api.md) — the tools themselves, and the rest of the HTTP surface

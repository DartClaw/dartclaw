# PostgreSQL

DartClaw uses SQLite by default. If the `database:` section is omitted, the authoritative store is
`<data_dir>/dartclaw.db` and no database server is required. PostgreSQL is an opt-in alternative for deployments
that need a separately operated relational database or PostgreSQL language-aware search.

## When to Use It

PostgreSQL 14 or newer is required. One deployment uses one database backend at a time, and a PostgreSQL
deployment uses one database and one connection pool. DartClaw relies only on core PostgreSQL features; it requires
no extension.

Choose PostgreSQL when its operating model is a good fit for your deployment. It moves authoritative relational data
to a separately administered service, so backups, access control, retention, and availability become shared concerns
with that service. SQLite remains the simpler default for a single-host installation.

## Configuration

Set `database.backend` to `postgres` and supply exactly one connection reference. An environment-substituted URL is
the usual choice:

```yaml
database:
  backend: postgres
  url: ${DARTCLAW_DATABASE_URL}
  pool_size: 5
  fts_language: english
```

Alternatively, store the DSN as a named generic API-key credential and reference its name:

```bash
dartclaw secrets set dartclaw-postgres --type api-key
```

```yaml
database:
  backend: postgres
  credential: dartclaw-postgres
  pool_size: 5
  fts_language: english
```

`url` and `credential` are mutually exclusive. A persisted URL containing an inline password is refused.
`pool_size` defaults to 5 and `fts_language` defaults to `english`. Every `database.*` setting requires a
restart. `dartclaw config` masks the URL and resolved credential value while leaving the credential name visible.

For the full field reference, see [Configuration](configuration.md). See
[Deployment](deployment.md#secrets-and-the-service-unit) for environment delivery and
[Security](security.md#named-credential-storage) for the named credential store.

For local development against a server without TLS, the environment value must opt out explicitly:

```bash
export DARTCLAW_DATABASE_URL='postgresql://dartclaw:<password>@127.0.0.1:5432/dartclaw?sslmode=disable'
```

Literal loopback keeps the driver's encrypted `require` default when `sslmode` is omitted, so a local server with
TLS disabled needs `?sslmode=disable`.

## Connection Security

The connection is trusted host-side egress. Agent tools cannot choose its destination or send SQL through it.
DartClaw evaluates the connection posture before creating a socket or pool:

| Destination and setting | Result |
|---|---|
| Non-loopback, `sslmode` omitted | Full certificate and hostname verification (`verify-full`) |
| Non-loopback, `verify-full` | Full certificate and hostname verification |
| Non-loopback, `verify-ca` | Upgraded to `verify-full` |
| Non-loopback, `require` | Encrypted, but certificate identity is not verified; `verify-full` is recommended |
| Non-loopback, `disable` | Refused |
| Literal loopback, `sslmode` omitted | Driver default `require` |
| Literal loopback, `disable` | Allowed for a local server without TLS |

The loopback exception covers only `localhost`, `127.0.0.1`, and `::1`. DartClaw uses the platform trust store and
does not load a custom CA bundle.

Connection failures, configuration output, and audit records never include the resolved DSN or password. Connection
open, close, and authentication failure events are audited with only the safe server identity and credential
reference.

## Provisioning

Run provisioning SQL as a database administrator, not as the DartClaw runtime role. The following example creates a
runtime role, its database, and a same-named schema that the role owns:

```sql
CREATE ROLE dartclaw
  LOGIN
  PASSWORD '<password>'
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOREPLICATION;
CREATE DATABASE dartclaw OWNER dartclaw;
```

Connect to the new `dartclaw` database as the administrator, then run:

```sql
CREATE SCHEMA IF NOT EXISTS dartclaw AUTHORIZATION dartclaw;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
```

Managed services may provide the database or restrict administrator statements. Apply the equivalent provider steps
so the runtime role owns its schema and can create and use DartClaw's current objects there, without superuser or
database-creation rights. DartClaw logs one startup warning if the runtime role is a superuser and continues.

## First Start and Schema Compatibility

A fresh PostgreSQL namespace is bootstrapped in one transaction. A compatible existing store opens without changing
its schema. Before using a non-empty store, DartClaw verifies its identity marker, current schema epoch, and required
objects.

A non-empty database without DartClaw's marker, or with a different epoch, is refused before use. The refusal names
the store and reports the expected and found epoch. Back up the store, then reset or recreate it for this release, or
restore a compatible backup. DartClaw does not rewrite an incompatible authoritative store into the current shape.
Incompatible derived search storage is rebuilt from complete supported sources or refused.

One serving process owns the PostgreSQL database through an advisory lock. A second `dartclaw serve` on the same
database fails loudly. Run one-shot database clients such as `dartclaw rebuild-index`, `dartclaw cleanup`, and
`dartclaw workflow status` with the server stopped. If PostgreSQL is unreachable at boot, DartClaw runs local crash
recovery first and then fails closed without serving.

## Search and Language

`database.fts_language` is one deployment-level PostgreSQL text-search configuration for memory documents,
conversation messages, and knowledge-graph facts. Changing it requires a restart and then
`dartclaw rebuild-index` for the stored memory and conversation vectors. Knowledge-graph facts use the new language
on their next query after restart. The wiki remains file-backed and is searched live. Tasks are never indexed.

PostgreSQL search has these limits:

- Snowball stemming matches regular inflections, such as `springa` and `springer`; the irregular English form
  `sprang` does not match `springa`.
- Mixed-language content is processed as the configured deployment language and can be mis-stemmed.
- PostgreSQL does not fold diacritics where SQLite FTS5 does.
- A query containing only stopwords returns no matches.
- Quoted phrases and `-word` negation use PostgreSQL web-search query syntax.

See [Search & Memory](search.md#postgresql-language-aware-search-opt-in) for how this relates to SQLite FTS5 and QMD,
and [CLI Reference](cli-reference.md#rebuild-index) for rebuild output and options.

## Operations and Backups

A managed PostgreSQL provider is a third-party data processor holding authoritative task data. Choose a provider and
region that meet your residency requirements, set retention deliberately, enable at-rest encryption, and control
operator access. Provider snapshots and their retention remain the operator's responsibility.

Use the provider's backup and restore tooling, or `pg_dump` and `pg_restore`, for the PostgreSQL database:

```bash
pg_dump --format=custom --file=dartclaw.dump "$DARTCLAW_DATABASE_URL"
pg_restore --dbname="$DARTCLAW_DATABASE_URL" dartclaw.dump
```

For SQLite, follow the backup and WAL-checkpoint procedure in
`dev/architecture/data-model.md#backup--recovery`. Always back up the file-based authoritative stores alongside
the selected database.

### Storage Tiers at a Glance

| Store | SQLite deployment | PostgreSQL deployment | Back up? | What is lost without it |
|---|---|---|---|---|
| Authoritative relational store | `<data_dir>/dartclaw.db` | Configured PostgreSQL database | Yes | Tasks, goals, executions, workflow runs, traces, events, and knowledge-graph facts |
| Derived search projections | `<data_dir>/search.db` | Memory and conversation search tables in PostgreSQL | No | Search availability until rebuilt from canonical memory and session NDJSON |
| Turn recovery | `<data_dir>/turn_state.json` | Same local file | No | Recovery context for turns interrupted by a crash |
| Webhook deduplication | `<data_dir>/webhook_deliveries/` | Same local directory | No | Recent reservation and delivery markers; duplicate delivery suppression may be lost |
| Sessions | `<data_dir>/sessions/` | Same local directory | Yes | Session metadata, conversation history, and the source for conversation-index rebuilds |
| Workspace | `<data_dir>/workspace/` | Same local directory | Yes | Identity files, canonical memory, wiki content, and workspace Git history |
| Configuration | `<data_dir>/dartclaw.yaml` | Same local file | Yes | Deployment configuration |
| Project registry | `<data_dir>/projects.json` | Same local file | Yes | Registered project metadata |
| Named credentials | `<data_dir>/credentials/named/` | Same local directory | Yes, as sensitive material | Stored credential values and their names |
| Audit and usage logs | `<data_dir>/audit-*.ndjson`, `usage.jsonl` | Same local files | If retained | Historical guard decisions and usage accounting |

An existing `tasks.db` is adopted as `dartclaw.db` before first use when only the old file exists. Startup refuses
when both exist. Leftover `state.db` and `webhook_deliveries.db` files are ignored and can be archived or deleted
after confirming the filesystem-backed replacements are in use.

## Switching and Decommissioning

Changing `database.backend` transfers no data. A fresh target starts empty; a compatible target reopens only the
data already stored in that target. Back up both sides before changing the setting.

After the active store passes its compatibility gate, startup reports a non-empty abandoned store. The SQLite check
is local. The PostgreSQL check is best effort and can report `could not verify` when the URL reference is
unresolvable, the server is unreachable, the connection posture is refused, or the schema is unknown. A lingering
`url` or `credential` under `backend: sqlite` is legal so this check can run.

To retire a PostgreSQL deployment:

1. Stop `dartclaw serve`.
2. Export or retain every record needed for audit or later recovery.
3. Take and verify a provider snapshot.
4. As the administrator, drop the DartClaw database and runtime role.
5. Remove the URL or credential reference from `dartclaw.yaml`.
6. Revoke and remove the environment secret or named credential.

For a retired SQLite store, retain or securely remove `dartclaw.db` after the same backup decision.

## Failure Reference

| Failure | Response |
|---|---|
| A second server reports the advisory lock is already held | Stop the competing server or point the deployments at separate databases |
| PostgreSQL is unreachable at boot | Restore network, DNS, credentials, or the database service, then restart; DartClaw does not serve after the failure |
| Lock recovery enters quarantine | Storage remains unavailable until ownership, PostgreSQL version, and current schema are revalidated; correct the reported condition and restart after a terminal failure |
| Schema compatibility is refused | Back up the named store, then reset or recreate it for this release, or restore a compatible backup |

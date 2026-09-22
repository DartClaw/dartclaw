# PostgreSQL

PostgreSQL 14 or newer is DartClaw's sole runtime database. A normal installation uses PostgreSQL's built-in
full-text search and needs neither pgvector nor an embedding provider. Hybrid search is an explicit opt-in that adds
both prerequisites.

PostgreSQL is operated separately from DartClaw. A native service is the default setup on macOS, Linux, and Windows;
a managed service or a container remains an operator choice. DartClaw does not bundle, install, supervise, or upgrade
the database server.

## Install a Native Service

Use an existing PostgreSQL 14+ installation when one is already available. Confirm the server, not only the client,
is new enough:

```sql
SHOW server_version;
```

### macOS with Homebrew

```bash
brew install postgresql@14
brew services start postgresql@14
"$(brew --prefix postgresql@14)/bin/pg_isready"
```

Homebrew runs the service as the signed-in user. Add the formula's `bin` directory to `PATH` if `psql` is not found.

### Debian or Ubuntu

Install a PostgreSQL 14+ package from the distribution or the PostgreSQL Apt repository, then enable the native
service:

```bash
sudo apt-get update
sudo apt-get install postgresql postgresql-client
sudo systemctl enable --now postgresql
sudo -u postgres pg_isready
```

Run `sudo -u postgres psql -tAc 'SHOW server_version'` and upgrade the cluster if it reports a version below 14.

### Windows x64

Install a current PostgreSQL release with the EnterpriseDB installer or WinGet. This example selects PostgreSQL 17:

```powershell
winget install --exact --id PostgreSQL.PostgreSQL.17
Get-Service 'postgresql*'
Start-Service (Get-Service 'postgresql*' | Select-Object -First 1).Name
```

Run SQL through the installed **SQL Shell (psql)**. The installer-created Windows service owns the server lifecycle;
DartClaw does not need a container engine.

## Provision as an Administrator

Installation and administrative provisioning are separate from runtime use. Connect as a PostgreSQL administrator
and create one restricted login plus its database:

```sql
CREATE ROLE dartclaw
  LOGIN
  PASSWORD '<replace-with-a-generated-password>'
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOREPLICATION;
CREATE DATABASE dartclaw OWNER dartclaw;
```

Reconnect to the new `dartclaw` database as the administrator, then create the role-owned application namespace:

```sql
CREATE SCHEMA IF NOT EXISTS dartclaw AUTHORIZATION dartclaw;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
```

The default PostgreSQL search path checks the schema named for the connected role before `public`, so the `dartclaw`
role uses its own namespace. The runtime role owns and updates DartClaw's application objects, but cannot create
databases, roles, or extensions. Keep the administrator credential out of `dartclaw.yaml`.

For explicit `search.backend: hybrid` only, the administrator also installs pgvector in `public`:

```sql
CREATE EXTENSION vector WITH SCHEMA public;
GRANT USAGE ON SCHEMA public TO dartclaw;
```

Lexical mode never probes or requires this extension. If hybrid mode cannot use `public.vector`, startup refuses with
remediation instead of silently dropping semantic search.

Managed services may replace these statements with provider controls. Preserve the same result: one database, a
non-superuser runtime role that owns its application namespace, and optional pgvector provisioned by an administrator.

## Configure the Connection

Supply exactly one connection reference. An environment-substituted URL is the usual choice:

```yaml
database:
  url: ${DARTCLAW_DATABASE_URL}
  pool_size: 5
  fts_language: english

search:
  backend: lexical
```

```bash
export DARTCLAW_DATABASE_URL='postgresql://dartclaw:<password>@127.0.0.1:5432/dartclaw?sslmode=disable'
```

Alternatively, save the URL as a named generic credential and reference its name:

```bash
dartclaw secrets set dartclaw-postgres --type api-key
```

```yaml
database:
  credential: dartclaw-postgres
  pool_size: 5
  fts_language: english
```

`url` and `credential` are mutually exclusive. A persisted URL containing an inline password is refused.
`pool_size` defaults to 5 and `fts_language` defaults to `english`; Swedish deployments can select `swedish`.
Every `database.*` setting requires a restart. `dartclaw config` masks the URL and resolved credential value while
leaving the credential name visible.

`database.backend` has been removed because there is no engine choice. During the 0.27 transition only, the exact
legacy value `database.backend: postgres` is accepted with removal guidance and ignored. `sqlite` and every other
engine value refuse. Similarly, `search.backend: fts5` is accepted only as a transition spelling for `lexical`; new
configuration uses `lexical` or explicit `hybrid`.

For environment delivery, see [Deployment](deployment.md#secrets-and-the-service-unit). For the complete field list,
see [Configuration](configuration.md).

## Connection Security

The connection is trusted host-side egress. Agent tools cannot choose its destination or send SQL through it.
DartClaw evaluates the connection posture before opening a socket or pool:

| Destination and setting | Result |
|---|---|
| Non-loopback, `sslmode` omitted | Full certificate and hostname verification (`verify-full`) |
| Non-loopback, `verify-full` | Full certificate and hostname verification |
| Non-loopback, `verify-ca` | Upgraded to `verify-full` |
| Non-loopback, `require` | Encrypted without certificate identity verification; `verify-full` is recommended |
| Non-loopback, `disable` | Refused |
| Literal loopback, `sslmode` omitted | Driver default `require` |
| Literal loopback, `disable` | Allowed for a local server without TLS |

The loopback exception covers only `localhost`, `127.0.0.1`, and `::1`. DartClaw uses the platform trust store and
does not load a custom CA bundle. Diagnostics and audit records never expose the resolved URL, password, or stored
records.

## Initialize and Check Readiness

Run `dartclaw init` to record the connection reference as part of initial setup. It remains usable before the database
is configured and reports missing, unreachable, authentication, TLS-posture, version, permission, and schema failures
separately.

After the administrator has created the role, database, and namespace, bootstrap an empty current schema:

```bash
dartclaw doctor
dartclaw doctor --fix
dartclaw doctor
```

`doctor --fix` uses the same `PostgresSchemaGate` as the runtime and may create DartClaw's objects only when the
application namespace is empty. It never creates a server, database, role, or extension, never resets a populated
schema, and never needs the administrator credential. A compatible current schema is left unchanged; a partial,
foreign, or incompatible schema refuses.

Help, version, init, configuration validation, and other database-independent commands remain available when
PostgreSQL is absent. Database-backed commands fail closed without a SQLite fallback. Stop the server before running
one-shot clients such as `dartclaw rebuild-index`, `dartclaw cleanup`, or standalone workflow maintenance.

## Search and Language

`search.backend: lexical` uses PostgreSQL full-text search for memory, conversations, and knowledge-graph facts. It
requires no vector extension, model download, or embedding call. `database.fts_language` selects one PostgreSQL text
search configuration for the deployment. After changing it, restart and run `dartclaw rebuild-index` so stored memory
and conversation projections use the new language.

`search.backend: hybrid` extends those lexical results with pgvector and the selected embedding provider. It does not
replace lexical search. See [Search & Memory](search.md) for provider configuration and recovery behavior.

## Back Up and Restore

The PostgreSQL database and canonical files are separate authorities and must be preserved separately.

```bash
pg_dump --format=custom --file=dartclaw.dump "$DARTCLAW_DATABASE_URL"
tar czf dartclaw-files.tar.gz \
  "$DARTCLAW_HOME/sessions" \
  "$DARTCLAW_HOME/workspace" \
  "$DARTCLAW_HOME/dartclaw.yaml" \
  "$DARTCLAW_HOME/projects.json" \
  "$DARTCLAW_HOME/credentials"
```

If `DARTCLAW_HOME` is unset, substitute the default `~/.dartclaw`. Treat the credential archive as sensitive. Audit
and usage logs are optional retention targets; `turn_state.json` and webhook deduplication state are instance-local.
Derived lexical and vector rows can be rebuilt and do not replace the canonical memory and session files.

Restore into an empty compatible deployment while DartClaw is stopped:

```bash
pg_restore --clean --if-exists --dbname="$DARTCLAW_DATABASE_URL" dartclaw.dump
tar xzf dartclaw-files.tar.gz -C /
dartclaw doctor
dartclaw rebuild-index
```

Use an archive layout and extraction destination appropriate to the paths captured on your host. Verify both the
database and canonical-file restore before serving traffic.

## Move a 0.26.1 SQLite Installation

The transition utility supports only the authoritative SQLite shape shipped by v0.26.1 at commit
`ef24b3302e936c4ff6183158da8462b866dbd7d2`. It is an offline, one-shot import into an empty current PostgreSQL schema,
not synchronization, merge, upsert, overwrite, or reverse migration.

1. Stop the v0.26.1 DartClaw process and keep it stopped.
2. Make a consistent SQLite backup that includes committed WAL data. Do not copy only the main database file while
   the old process is running.
3. Back up `sessions/`, `workspace/`, configuration, projects, credentials, and any retained logs separately. The
   database importer never copies or changes canonical files.
4. Install/provision PostgreSQL, configure the restricted runtime role, and run `dartclaw doctor --fix`. Do not start
   DartClaw against the target; the target must contain the current schema and no application rows.
5. Export libpq settings for that same target and role. The importer inherits `PGHOST`, `PGPORT`, `PGDATABASE`,
   `PGUSER`, and the normal service/passfile/TLS/password mechanisms; it accepts no target URL argument.
6. Run the importer and keep its table-count receipt:

   ```bash
   python3 dev/tools/migrate_sqlite_to_postgres.py <stopped-backup.db>
   ```

7. Run `dartclaw doctor`, then `dartclaw rebuild-index`. The importer intentionally excludes derived lexical and
   vector tables; those rebuild from the unchanged canonical files.
8. Start DartClaw, run an operator smoke check, and take a new PostgreSQL-plus-files backup before retiring the old
   installation.

The importer verifies the exact source manifest, target compatibility and emptiness, row values and counts,
constraints, relationships, and the next knowledge-fact identity inside one transaction. Failure rolls back the
target and leaves the supplied snapshot and canonical files unchanged. Unsupported, ambiguous, populated, repeated,
or concurrently active targets refuse. Success prints `Migration completed.`, one `<table>: <n> rows` line for each
of the ten authoritative tables, and a reminder to rebuild from the separately backed-up canonical files. Refusals
use `Migration refused [<safe-class>]` and do not print credentials or record content.

Retain the old binary, configuration, SQLite snapshot, and canonical-file backup until the new deployment is
accepted. Rolling back to them is safe only before any new PostgreSQL writes are accepted. After new writes, there is
no supported reverse conversion or lossless rollback. Choosing a fresh start is explicit: bootstrap an empty target,
skip the importer, and accept that the old relational records do not move.

## Failure Reference

| Failure | Response |
|---|---|
| Connection reference is missing | Add exactly one `database.url` or `database.credential`; database-independent commands remain available |
| PostgreSQL is unreachable | Restore the native service, network, DNS, or credentials, then rerun `dartclaw doctor` |
| Runtime role is a superuser | Re-provision a restricted login; the warning does not grant permission to use an administrator credential at runtime |
| Runtime role lacks schema permissions | Make it owner of its application schema; do not grant superuser, role-creation, database-creation, or extension-creation rights |
| Server is older than PostgreSQL 14 | Upgrade the server/cluster before using DartClaw |
| Schema compatibility is refused | Preserve a backup, then use an empty current schema or restore a backup made by the same schema epoch |
| A second server reports the advisory lock is held | Stop the competing process or use a separate database |
| Hybrid reports pgvector unavailable | Have an administrator install `vector` in `public`; lexical mode does not require it |
| Vector recovery remains incomplete | Repair the embedding provider, stop DartClaw, and rerun `dartclaw rebuild-index`; lexical search remains available |

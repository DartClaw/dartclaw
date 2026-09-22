# Deprecated Configuration Keys

These are the only removed configuration paths the 0.27 loader recognizes for bounded transition diagnostics. They
do not restore an old runtime branch, fallback, or search implementation.

| Removed path | 0.27 behavior | Replacement |
|---|---|---|
| `database.backend` | The exact value `postgres` is accepted with a removal advisory and normalized to the sole PostgreSQL path. `sqlite` and every other value refuse. | Delete the key. Configure exactly one of `database.url` or `database.credential`. |
| `search.qmd` | The retired QMD settings subtree is accepted only so the loader can issue removal guidance; it does not start or select QMD. | Delete the subtree. Use `search.backend: lexical`, or configure explicit `hybrid` plus an embedding provider. |

The exact old value `search.backend: fts5` is also accepted for the 0.27 transition, warns, and normalizes to
`lexical`. `search.backend: qmd` and every other unsupported value produce a blocking invalid-value refusal; the
typed value normalizes to lexical only so diagnostics can continue, not so runtime may start. Newly generated
configuration contains none of these old spellings.

Remove deprecated keys after reviewing the advisory. Their acceptance is a one-release parsing concession, not a
promise that later releases will continue to load them.

# ADR-049 Research: Typed Platform Capability Surface

## Compared options

| Option | Auditability | Minimalism | Testability | Consumer fit | Change surface | Weighted |
|---|---:|---:|---:|---:|---:|---:|
| **Flat typed object** | 5 | 5 | 5 | 5 | 4 | **4.90** |
| Typed category objects | 5 | 3 | 5 | 5 | 3 | 4.30 |
| Enum-keyed table | 3 | 4 | 5 | 4 | 4 | 3.90 |
| OS subclasses | 4 | 2 | 5 | 4 | 2 | 3.50 |
| Operational service | 3 | 2 | 3 | 4 | 2 | 2.80 |

Weights: auditability/security honesty 30%, minimalism/approachability 25%, deterministic testing 20%, S03–S07 fit 15%, migration surface 10%.

## Evidence summary

- `dartclaw_config` favors plain typed values and small enums.
- Home expansion already has an injectable environment seam.
- The known consumers need distinct, named decisions rather than a heterogeneous registry.
- Executable lookup and shell startup are effectful consumer work; keeping the capability value pure makes dual-platform tests deterministic.

The flat typed value wins because it exposes every current security-relevant claim directly with the least structure. Typed category objects are the only credible future migration if accepted capabilities make the flat surface crowded.

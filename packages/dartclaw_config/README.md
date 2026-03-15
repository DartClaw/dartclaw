# dartclaw_config

Shared configuration metadata, validation, YAML writing, and scope reconciliation
utilities for the DartClaw runtime.

`dartclaw_config` is the reusable config package extracted from
`dartclaw_server`. It provides:

- `ConfigMeta` for canonical field metadata and JSON key mapping
- `ConfigValidator` for API and CLI update validation
- `ConfigWriter` for non-destructive YAML writes with backup + atomic replace
- `ScopeReconciler` for applying live session scope changes from config events

`ConfigSerializer` and `ConfigChangeSubscriber` remain in `dartclaw_server`
because they depend on server-only runtime types.

## License

MIT - see [LICENSE](LICENSE).

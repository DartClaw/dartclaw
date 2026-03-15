/// Shared configuration metadata, validation, and authoring utilities for DartClaw.
library;

export 'src/config_meta.dart' show ConfigMeta, ConfigMutability, ConfigFieldType, FieldMeta;
export 'src/config_validator.dart' show ConfigValidator, ValidationError;
export 'src/config_writer.dart' show ConfigWriter;
export 'src/scope_reconciler.dart' show ScopeReconciler;

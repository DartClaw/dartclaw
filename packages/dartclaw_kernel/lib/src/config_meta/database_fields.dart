part of '../config_meta.dart';

const Map<String, FieldMeta> _databaseFields = {
  'database.backend': FieldMeta(
    yamlPath: 'database.backend',
    jsonKey: 'database.backend',
    type: ConfigFieldType.enum_,
    mutability: ConfigMutability.restart,
    description: 'Authoritative database engine. Defaults to sqlite; postgres requires a URL or named credential.',
    allowedValues: ['sqlite', 'postgres'],
  ),
  'database.url': FieldMeta(
    yamlPath: 'database.url',
    jsonKey: 'database.url',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.readonly,
    description: 'PostgreSQL connection URL supplied through environment substitution. Read-only: secret material is never editable through the API.',
    nullable: true,
  ),
  'database.credential': FieldMeta(
    yamlPath: 'database.credential',
    jsonKey: 'database.credential',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.readonly,
    description: 'Named generic API-key credential containing the PostgreSQL connection URL. Read-only: credential references are configured in YAML.',
    nullable: true,
  ),
  'database.pool_size': FieldMeta(
    yamlPath: 'database.pool_size',
    jsonKey: 'database.poolSize',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Maximum PostgreSQL connections. Defaults to 5.',
    min: 1,
  ),
  'database.fts_language': FieldMeta(
    yamlPath: 'database.fts_language',
    jsonKey: 'database.ftsLanguage',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'PostgreSQL text-search configuration name. Defaults to english; changing it requires restart and rebuild-index.',
  ),
};

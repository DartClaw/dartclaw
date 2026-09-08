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
    mutability: ConfigMutability.restart,
    description: 'PostgreSQL connection URL. Environment references are resolved when configuration loads.',
    nullable: true,
  ),
  'database.credential': FieldMeta(
    yamlPath: 'database.credential',
    jsonKey: 'database.credential',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Named credential containing the PostgreSQL connection URL.',
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
};

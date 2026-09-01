part of '../config_meta_test.dart';

void _expectDeclarationMatchesDisposition(String path, _DispositionRow row) {
  if (row.disposition == _Disposition.retired) {
    expect(ConfigMeta.isKnown(path), isFalse, reason: '$path is recorded retired but is registered again');
    return;
  }
  if (row.disposition == _Disposition.loaderMembershipResidual) {
    expect(row.consequence, isNotEmpty, reason: '$path residual has no rationale');
    return;
  }
  final field = ConfigMeta.fields[path];
  expect(field, isNotNull, reason: '$path is ruled on but is not registered');
  expect(field!.type, _declaredTypeFor(row.disposition), reason: '$path type');
  expect(field.min, row.min, reason: '$path min');
  expect(field.max, row.max, reason: '$path max');
  expect(field.allowedValues, row.allowedValues, reason: '$path allowedValues');
}

ConfigFieldType _declaredTypeFor(_Disposition disposition) => switch (disposition) {
  _Disposition.declaredMax || _Disposition.maxDropped || _Disposition.agrees => ConfigFieldType.int_,
  _Disposition.agreesFraction => ConfigFieldType.double_,
  _Disposition.derivedMembership => ConfigFieldType.enum_,
  _Disposition.declaredNotEnforcedOnWrite || _Disposition.inexpressible => ConfigFieldType.string,
  _Disposition.loaderMembershipResidual ||
  _Disposition.retired => throw StateError('a residual or retired path has no declaration to type'),
};

Iterable<String> _pathsRuled(_Disposition disposition) => _registryDispositions
    .expand((section) => section.entries)
    .where((entry) => entry.value.disposition == disposition)
    .map((entry) => entry.key);

const _derivedMembershipSources = <String, String>{
  'search.backend': 'config_parser_providers.dart',
  'guards.content.classifier': 'config_parser_security.dart',
  'gateway.reload.mode': 'config_parser.dart',
  'gateway.auth_mode': 'config_parser.dart',
  'sessions.maintenance.mode': 'config_parser.dart',
  'context.identifier_preservation': 'config_parser.dart',
  'governance.queue_strategy': 'config_parser_governance.dart',
  'governance.turn_limits.stall_action': 'config_parser_governance.dart',
  'governance.budget.action': 'config_parser_governance.dart',
  'governance.loop_detection.action': 'config_parser_governance.dart',
  'workflow.runtime_artifacts_retention.mode': 'workflow_config.dart',
  'tasks.worktree.merge_strategy': 'config_parser.dart',
};

typedef _ExternalMembershipSource = ({String source, String fieldToken});

const _outOfPackageDerivedMembershipSources = <String, _ExternalMembershipSource>{
  'channels.whatsapp.dm_access': (
    source: 'packages/dartclaw_core/lib/src/scoping/common_channel_fields.dart',
    fieldToken: "ConfigMeta.fields['channels.\$channelName.dm_access']!",
  ),
  'channels.whatsapp.group_access': (
    source: 'packages/dartclaw_core/lib/src/scoping/common_channel_fields.dart',
    fieldToken: "ConfigMeta.fields['channels.\$channelName.group_access']!",
  ),
  'channels.signal.dm_access': (
    source: 'packages/dartclaw_core/lib/src/scoping/common_channel_fields.dart',
    fieldToken: "ConfigMeta.fields['channels.\$channelName.dm_access']!",
  ),
  'channels.signal.group_access': (
    source: 'packages/dartclaw_core/lib/src/scoping/common_channel_fields.dart',
    fieldToken: "ConfigMeta.fields['channels.\$channelName.group_access']!",
  ),
  'channels.google_chat.dm_access': (
    source: 'packages/dartclaw_core/lib/src/scoping/common_channel_fields.dart',
    fieldToken: "ConfigMeta.fields['channels.\$channelName.dm_access']!",
  ),
  'channels.google_chat.group_access': (
    source: 'packages/dartclaw_core/lib/src/scoping/common_channel_fields.dart',
    fieldToken: "ConfigMeta.fields['channels.\$channelName.group_access']!",
  ),
  'channels.google_chat.typing_indicator': (
    source: 'packages/dartclaw_google_chat/lib/src/google_chat_config.dart',
    fieldToken: "ConfigMeta.fields['channels.google_chat.typing_indicator']!",
  ),
  'channels.google_chat.reactions_auth': (
    source: 'packages/dartclaw_google_chat/lib/src/google_chat_config.dart',
    fieldToken: "ConfigMeta.fields['channels.google_chat.reactions_auth']!",
  ),
  'channels.google_chat.audience.type': (
    source: 'packages/dartclaw_google_chat/lib/src/google_chat_config.dart',
    fieldToken: "ConfigMeta.fields['channels.google_chat.audience.type']!",
  ),
  'channels.google_chat.feedback.status_style': (
    source: 'packages/dartclaw_google_chat/lib/src/google_chat_config.dart',
    fieldToken: "ConfigMeta.fields['channels.google_chat.feedback.status_style']!",
  ),
};

const _membershipResidualReasons = <String, String>{
  'sessions.dm_scope': 'The mapper accepts underscore aliases absent from the declaration.',
  'sessions.group_scope': 'The mapper accepts underscore aliases absent from the declaration.',
  'logging.level': 'The loader applies no membership check.',
  'logging.format': 'The loader applies no membership check.',
  'agent.execution': 'ExecutionPolicy owns the typed mapping outside the config parser.',
  'top-level config key acceptance': 'The registry-derived acceptance sweep owns top-level membership.',
  'recognized model advisory': 'Model recognition is advisory and has no closed operator-facing enum.',
  'search.qmd.host syntax': 'Loopback-host syntax is a semantic string constraint, not an enum.',
  'providers.<id>.*': 'The values belong to the providers entry shape.',
  'mcp_servers.<id>.network_class': 'The value belongs to the MCP servers entry shape.',
  'harness.acp.agents.<id>.*': 'The values belong to an out-of-package ACP entry shape.',
  'projects.<id>.*': 'The values belong to the projects entry shape.',
  'sessions.channels.<key>.*': 'The values belong to the session-channel entry shape.',
  'scheduling.jobs[].type': 'The value belongs to the scheduling jobs entry shape.',
  'channels.google_chat.quote_reply': 'The declaration omits four compatibility spellings the loader accepts.',
  'channels.<channel>.max_chunk_size': 'Google Chat has no registration, so the shared parse path is not total.',
  'agent.agents.<id>.{security_profile,execution}':
      'The values belong to the agent entry shape rather than resolvable scalar fields.',
  'gateway.mcp_clients':
      'The loader refuses the list unless gateway.auth_mode is token — a cross-field precondition, '
      'not a membership constraint the entry shape could declare.',
};

const _externalConstraintInventory = <String, List<String>>{
  'packages/dartclaw_core/lib/src/scoping/common_channel_fields.dart|if (raw is int && raw > 0) return raw;': [
    'channels.<channel>.max_chunk_size',
  ],
  'packages/dartclaw_core/lib/src/scoping/common_channel_fields.dart|if (FieldConstraints.evaluate(fieldMeta, raw) == null) {':
      [
        'channels.whatsapp.dm_access',
        'channels.whatsapp.group_access',
        'channels.signal.dm_access',
        'channels.signal.group_access',
        'channels.google_chat.dm_access',
        'channels.google_chat.group_access',
      ],
  'packages/dartclaw_google_chat/lib/src/google_chat_config.dart|pollIntervalSeconds = FieldConstraints.evaluate(field, pollIntervalRaw) == null ? pollIntervalRaw : min;':
      ['channels.google_chat.pubsub.poll_interval_seconds'],
  'packages/dartclaw_google_chat/lib/src/google_chat_config.dart|if (FieldConstraints.evaluate(field, maxMessagesRaw) == null) {':
      ['channels.google_chat.pubsub.max_messages_per_pull'],
  'packages/dartclaw_google_chat/lib/src/google_chat_config.dart|final parsed = tryParseDuration(minFeedbackDelayRaw);':
      ['channels.google_chat.feedback.min_feedback_delay'],
  'packages/dartclaw_google_chat/lib/src/google_chat_config.dart|final parsed = tryParseDuration(statusIntervalRaw);': [
    'channels.google_chat.feedback.status_interval',
  ],
  'packages/dartclaw_google_chat/lib/src/google_chat_config.dart|if (FieldConstraints.evaluate(field, statusStyleRaw) == null) {':
      ['channels.google_chat.feedback.status_style'],
  'packages/dartclaw_google_chat/lib/src/google_chat_config.dart|if (FieldConstraints.evaluate(field, typingIndicatorRaw) == null) {':
      ['channels.google_chat.typing_indicator'],
  'packages/dartclaw_google_chat/lib/src/google_chat_config.dart|typingIndicatorMode = switch (typingIndicatorRaw) {': [
    'channels.google_chat.typing_indicator',
  ],
  'packages/dartclaw_google_chat/lib/src/google_chat_config.dart|quoteReplyMode = switch (quoteReplyRaw) {': [
    'channels.google_chat.quote_reply',
  ],
  'packages/dartclaw_google_chat/lib/src/google_chat_config.dart|if (FieldConstraints.evaluate(field, reactionsAuthRaw) == null) {':
      ['channels.google_chat.reactions_auth'],
  'packages/dartclaw_google_chat/lib/src/google_chat_config.dart|final mode = switch (type) {': [
    'channels.google_chat.audience.type',
  ],
  "packages/dartclaw_google_chat/lib/src/google_chat_config.dart|String() when FieldConstraints.evaluate(ConfigMeta.fields['channels.google_chat.audience.type']!, type) == null =>":
      ['channels.google_chat.audience.type'],
  'packages/dartclaw_google_chat/lib/src/google_chat_config.dart|switch (type) {': [
    'channels.google_chat.audience.type',
  ],
  'packages/dartclaw_signal/lib/src/signal_config.dart|if (FieldConstraints.evaluate(field, portRaw) == null) {': [
    'channels.signal.port',
  ],
  'packages/dartclaw_kernel/lib/src/agent_definition.dart|} else if (profile is String && containerSecurityProfiles.contains(profile)) {':
      ['agent.agents.<id>.{security_profile,execution}'],
  "packages/dartclaw_kernel/lib/src/agent_definition.dart|final execution = _parseExecutionMode(yaml['execution'], 'agent.agents.\$id.execution');":
      ['agent.agents.<id>.{security_profile,execution}'],
};

const _membershipLiteralResiduals = <String, List<String>>{
  'top-level config key acceptance': ['config_parser.dart|if (!_knownKeys.contains(key)) {'],
  'recognized model advisory': [
    'config_parser.dart|if (_recognizedClaudeModels.hasMatch(lower) || _recognizedCodexModels.contains(lower)) return;',
  ],
  'scheduling.jobs[].type': ["config_parser.dart|if (typeStr == 'task') {"],
  'knowledge.inbox.delivery_mode': [
    "config_parser.dart|if (value == 'none' || value == 'announce' || value == 'webhook') return value;",
  ],
  'tasks.completion_action': [
    "config_parser.dart|if (trimmedCompletionAction == 'review' || trimmedCompletionAction == 'accept') {",
  ],
  'search.qmd.host syntax': [
    "config_parser_providers.dart|if (normalized == '[::1]') normalized = '::1';",
    "config_parser_providers.dart|if (normalized == 'localhost' || normalized == '::1') return normalized;",
    "config_parser_providers.dart|octets.first == '127' &&",
  ],
  'providers.<id>.*': [
    'config_parser_providers.dart|if (raw is! String || !ClaudeProviderOptions.approvalValues.contains(raw)) {',
    "config_parser_providers.dart|if (raw == 'never') {",
    'config_parser_providers.dart|if (raw is! String || !ClaudeProviderOptions.sandboxValues.contains(raw)) {',
  ],
  'mcp_servers.<id>.network_class': ["config_parser_providers.dart|(uri.scheme != 'http' && uri.scheme != 'https') ||"],
  'gateway.mcp_clients': ["config_parser.dart|if (authMode != 'token') {"],
};

const _scalarMembershipResiduals = [
  'sessions.dm_scope',
  'sessions.group_scope',
  'logging.level',
  'logging.format',
  'agent.execution',
];

const _entryMembershipResidualRoots = <String, String>{
  'providers.<id>.*': 'providers',
  'mcp_servers.<id>.network_class': 'mcp_servers',
  'harness.acp.agents.<id>.*': 'harness.acp.agents',
  'projects.<id>.*': 'projects',
  'sessions.channels.<key>.*': 'sessions.channels',
  'scheduling.jobs[].type': 'scheduling.jobs',
};

final _derivedMembershipDeclarations = <String, _DispositionRow>{
  for (final entry in _derivedMembershipSources.entries)
    if (entry.key != 'gateway.auth_mode')
      entry.key: (
        disposition: _Disposition.derivedMembership,
        min: null,
        max: null,
        allowedValues: ConfigMeta.fields[entry.key]!.allowedValues,
        consequence: 'Membership derives from ${entry.value}.',
      ),
  for (final entry in _outOfPackageDerivedMembershipSources.entries)
    entry.key: (
      disposition: _Disposition.derivedMembership,
      min: null,
      max: null,
      allowedValues: ConfigMeta.fields[entry.key]!.allowedValues,
      consequence: 'Membership derives from ${entry.value.source}.',
    ),
};

final _membershipResiduals = <String, _DispositionRow>{
  for (final entry in _membershipResidualReasons.entries)
    entry.key: (
      disposition: _Disposition.loaderMembershipResidual,
      min: null,
      max: null,
      allowedValues: null,
      consequence: entry.value,
    ),
};

void _registerConfigMembershipDispositionTests() {
  test('enum membership loaders derive from declarations or carry one residual ruling', () async {
    final sourceDir = await _packageLibDir();
    final sources = <String, String>{};
    for (final entry in _derivedMembershipSources.entries) {
      final source = sources.putIfAbsent(
        entry.value,
        () => File(p.join(sourceDir, 'src', entry.value)).readAsStringSync(),
      );
      final fieldToken = "ConfigMeta.fields['${entry.key}']!";
      final offset = source.indexOf(fieldToken);
      expect(offset, isNonNegative, reason: entry.key);
      final end = offset + 500 < source.length ? offset + 500 : source.length;
      final site = source.substring(offset, end);
      expect(site, contains('FieldConstraints.evaluate(field,'), reason: entry.key);
    }
    final repositoryRoot = _repositoryRoot(await _packageLibDir());
    for (final entry in _outOfPackageDerivedMembershipSources.entries) {
      final source = File(p.join(repositoryRoot, entry.value.source)).readAsStringSync();
      final offset = source.indexOf(entry.value.fieldToken);
      expect(offset, isNonNegative, reason: entry.key);
      if (entry.value.source.contains('common_channel_fields.dart')) {
        expect(source, contains('FieldConstraints.evaluate(fieldMeta, raw)'), reason: entry.key);
      } else {
        final start = offset > 100 ? offset - 100 : 0;
        final end = offset + 500 < source.length ? offset + 500 : source.length;
        expect(source.substring(start, end), contains('FieldConstraints.evaluate('), reason: entry.key);
      }
    }
    expect(_derivedMembershipDeclarations, hasLength(21));
    expect(_membershipResiduals, hasLength(18));
    expect(_membershipResidualReasons.values, everyElement(isNotEmpty));
    final ruled = _registryDispositions.expand((section) => section.keys).toList();
    expect(ruled, unorderedEquals(ruled.toSet()), reason: 'a path carries more than one disposition');
    expect(
      _pathsRuled(_Disposition.derivedMembership),
      unorderedEquals({..._derivedMembershipSources.keys, ..._outOfPackageDerivedMembershipSources.keys}),
    );
    final ruledPaths = _registryDispositions.expand((section) => section.keys).toSet();
    expect(_membershipLiteralResiduals.keys, everyElement(isIn(ruledPaths)));
    expect(_externalConstraintInventory.values.expand((paths) => paths), everyElement(isIn(ruledPaths)));
    expect(_scalarMembershipResiduals, everyElement(isIn(ConfigMeta.fields.keys)));
    for (final entry in _entryMembershipResidualRoots.entries) {
      expect(ConfigMeta.fields[entry.value]?.entry, isNotNull, reason: entry.key);
    }
    final literalSites = await _membershipLiteralSites();
    final ruledLiteralSites = _membershipLiteralResiduals.values.expand((sites) => sites).toSet();
    expect(literalSites, unorderedEquals(ruledLiteralSites), reason: 'literal membership sites without a disposition');
    final externalSites = await _externalConstraintSites(repositoryRoot);
    expect(
      externalSites,
      unorderedEquals(_externalConstraintInventory.keys),
      reason: 'external constraint sites without exactly one inventory ruling',
    );
  });

  test('literal membership scan catches an unruled site', () {
    expect(
      _membershipLiteralSitesInSource('synthetic.dart', "if (value == 'alpha' || value == 'beta') return value;"),
      {'synthetic.dart|if (value == \'alpha\' || value == \'beta\') return value;'},
    );
  });

  test('external constraint scan catches unruled membership and mapper sites', () {
    expect(
      _externalConstraintSitesInSource(
        'synthetic.dart',
        "if (raw == 'alpha') return;\nfinal mapped = switch (newRaw) { 'alpha' => 1, _ => 0 };",
      ),
      {
        "synthetic.dart|if (raw == 'alpha') return;",
        "synthetic.dart|final mapped = switch (newRaw) { 'alpha' => 1, _ => 0 };",
      },
    );
  });

  test('derived typed mappers accept exactly their registered spellings', () {
    final mapperSpellings = <String, Set<String>>{
      'sessions.maintenance.mode': MaintenanceMode.values.map((value) => value.name).toSet(),
      'context.identifier_preservation': IdentifierPreservationMode.values.map((value) => value.toJson()).toSet(),
      'governance.queue_strategy': QueueStrategy.values.map((value) => value.name).toSet(),
      'governance.turn_limits.stall_action': TurnProgressAction.values.map((value) => value.name).toSet(),
      'governance.budget.action': BudgetAction.values.map((value) => value.name).toSet(),
      'governance.loop_detection.action': LoopAction.values.map((value) => value.name).toSet(),
      'workflow.runtime_artifacts_retention.mode': MaintenanceMode.values.map((value) => value.name).toSet(),
      'workflow.approvals': WorkflowApprovalPolicy.values.map((value) => value.yamlValue).toSet(),
    };

    for (final entry in mapperSpellings.entries) {
      final declared = ConfigMeta.fields[entry.key]!.allowedValues!.toSet();
      expect(declared, entry.value, reason: '${entry.key}: declared $declared; mapper accepts ${entry.value}');
    }
  });

  test('session scope aliases remain a recorded membership residual', () {
    final config = DartclawConfig.load(
      configPath: 'dartclaw.yaml',
      fileReader: (path) =>
          path == 'dartclaw.yaml' ? 'sessions:\n  dm_scope: per_contact\n  group_scope: per_member\n' : null,
      env: const {'HOME': '/home/user'},
    );

    expect(config.sessions.scopeConfig.dmScope, DmScope.perContact);
    expect(config.sessions.scopeConfig.groupScope, GroupScope.perMember);
    expect(config.warnings, isEmpty);
  });
}

String _repositoryRoot(String packageLibDir) => p.normalize(p.join(packageLibDir, '..', '..', '..'));

Future<Set<String>> _externalConstraintSites(String repositoryRoot) async {
  const files = [
    'packages/dartclaw_core/lib/src/scoping/common_channel_fields.dart',
    'packages/dartclaw_google_chat/lib/src/google_chat_config.dart',
    'packages/dartclaw_signal/lib/src/signal_config.dart',
    'packages/dartclaw_kernel/lib/src/agent_definition.dart',
  ];
  return {
    for (final file in files)
      ..._externalConstraintSitesInSource(file, File(p.join(repositoryRoot, file)).readAsStringSync()),
  };
}

Set<String> _externalConstraintSitesInSource(String fileName, String source) {
  final withoutComments = source.replaceAll(RegExp(r'//[^\n]*|/\*[\s\S]*?\*/'), '');
  final channelSite = RegExp(
    r'''FieldConstraints\.evaluate\(|tryParseDuration\(|switch\s*\((?:\w+Raw|type)\)|(?:==|!=)\s*(['"])[^'"\n]+\1|[<>]=?\s*-?\d|\.contains\(''',
  );
  final agentSite = RegExp(r'''containerSecurityProfiles\.contains\(|_parseExecutionMode\(yaml\['execution'\]''');
  final pattern = fileName.endsWith('agent_definition.dart') ? agentSite : channelSite;
  return {
    for (final line in withoutComments.split('\n'))
      if (pattern.hasMatch(line)) '$fileName|${line.trim().replaceAll(RegExp(r'\s+'), ' ')}',
  };
}

Future<Set<String>> _membershipLiteralSites() async {
  final sourceDir = Directory(p.join(await _packageLibDir(), 'src'));
  final files = sourceDir.listSync().whereType<File>().where((file) {
    final name = p.basename(file.path);
    return name == 'workflow_config.dart' || name.startsWith('config_parser');
  });
  return {for (final file in files) ..._membershipLiteralSitesInSource(p.basename(file.path), file.readAsStringSync())};
}

Set<String> _membershipLiteralSitesInSource(String fileName, String source) {
  final withoutComments = source.replaceAll(RegExp(r'//[^\n]*|/\*[\s\S]*?\*/'), '');
  final membership = RegExp(
    r'''(?:==|!=)\s*(['"])(?!true\1|false\1)[^'"\n]+\1|!?[A-Za-z_]\w*(?:\.\w+)*\.contains\([^)]*\)''',
  );
  return {
    for (final line in withoutComments.split('\n'))
      if (membership.hasMatch(line)) '$fileName|${line.trim().replaceAll(RegExp(r'\s+'), ' ')}',
  };
}

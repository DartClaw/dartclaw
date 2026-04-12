import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';

class GitHubWorkflowTrigger {
  final String event;
  final List<String> actions;
  final List<String> labels;
  final String workflow;

  const GitHubWorkflowTrigger({
    required this.event,
    required this.actions,
    required this.labels,
    required this.workflow,
  });
}

class GitHubWebhookConfig {
  final bool enabled;
  final String? webhookSecret;
  final String webhookPath;
  final List<GitHubWorkflowTrigger> triggers;

  const GitHubWebhookConfig({
    this.enabled = false,
    this.webhookSecret,
    this.webhookPath = '/webhook/github',
    this.triggers = const [
      GitHubWorkflowTrigger(
        event: 'pull_request',
        actions: ['opened', 'synchronize'],
        labels: [],
        workflow: 'code-review',
      ),
    ],
  });

  const GitHubWebhookConfig.defaults() : this();
}

bool _githubWebhookConfigRegistered = false;

void ensureGitHubWebhookConfigRegistered() {
  if (_githubWebhookConfigRegistered) {
    return;
  }
  DartclawConfig.registerExtensionParser('github', (yaml, warns) => parseGitHubWebhookConfig(yaml, warns));
  _githubWebhookConfigRegistered = true;
}

GitHubWebhookConfig parseGitHubWebhookConfig(Map<String, dynamic> yaml, List<String> warns) {
  final enabled = yaml['enabled'] == true;
  final webhookSecret = _expandEnv(yaml['webhook_secret'] as String?);
  final webhookPath = (yaml['webhook_path'] as String?)?.trim();
  final triggers = (yaml['triggers'] as List?)
      ?.whereType<Map<String, dynamic>>()
      .map(
        (entry) => GitHubWorkflowTrigger(
          event: (entry['event'] as String?)?.trim() ?? 'pull_request',
          actions:
              (entry['actions'] as List?)?.map((value) => value.toString()).toList() ?? const ['opened', 'synchronize'],
          labels: (entry['labels'] as List?)?.map((value) => value.toString()).toList() ?? const [],
          workflow: (entry['workflow'] as String?)?.trim() ?? 'code-review',
        ),
      )
      .toList(growable: false);
  if (enabled && (webhookSecret == null || webhookSecret.isEmpty)) {
    warns.add('github.webhook_secret is missing while github.enabled=true');
  }
  return GitHubWebhookConfig(
    enabled: enabled,
    webhookSecret: webhookSecret,
    webhookPath: webhookPath == null || webhookPath.isEmpty ? '/webhook/github' : webhookPath,
    triggers: triggers == null || triggers.isEmpty ? const GitHubWebhookConfig.defaults().triggers : triggers,
  );
}

String? _expandEnv(String? value) {
  if (value == null) {
    return null;
  }
  final match = RegExp(r'^\$\{([A-Z0-9_]+)\}$').firstMatch(value.trim());
  if (match == null) {
    return value;
  }
  final name = match.group(1);
  if (name == null) {
    return null;
  }
  return Platform.environment[name];
}

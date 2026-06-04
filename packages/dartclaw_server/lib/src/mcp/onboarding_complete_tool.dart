import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;

/// MCP tool that marks conversational onboarding complete by clearing ONBOARDING.md.
///
/// Only effective for onboarding-eligible web sessions. Pass [onboardingActive] as
/// `false` to disable the tool for non-onboarding contexts (task/cron/channel
/// agents) — calls from those contexts return a refusal rather than deleting the
/// sentinel.
///
/// Architectural note: DartClaw exposes a single global MCP server with no
/// per-session tool sets, so eligibility is enforced at the tool level rather than
/// via per-scope registration. Registration-time conditional ([onboardingActive])
/// skips the tool entirely when ONBOARDING.md is absent at startup; the runtime
/// check inside [call] guards late calls in the same session.
class OnboardingCompleteTool implements McpTool {
  final String workspaceDir;

  /// When false the tool refuses to act, protecting against task/cron/channel
  /// agents that share the same MCP surface prematurely clearing onboarding state.
  final bool onboardingActive;

  OnboardingCompleteTool({required this.workspaceDir, this.onboardingActive = true});

  @override
  String get name => 'onboarding_complete';

  @override
  String get description => 'Mark conversational onboarding complete and remove the ONBOARDING.md sentinel.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': <String, dynamic>{},
    'additionalProperties': false,
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    if (!onboardingActive) {
      return const ToolResult.text('onboarding_complete is not available in this context.');
    }

    final file = File(p.join(workspaceDir, 'ONBOARDING.md'));
    if (!file.existsSync()) {
      return const ToolResult.text('Onboarding is already complete: ONBOARDING.md is absent.');
    }

    try {
      file.deleteSync();
      return const ToolResult.text('Onboarding complete: ONBOARDING.md removed.');
    } on FileSystemException catch (e) {
      return ToolResult.error('Failed to remove ONBOARDING.md: ${e.message}');
    }
  }
}

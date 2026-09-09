part of 'harness_wiring.dart';

HarnessLaunchOptions _workerHarnessOptions({
  required HarnessLaunchOptions base,
  required ({String? model, String? effort})? providerOptions,
  required String appendSystemPrompt,
  required List<String> disallowedTools,
}) {
  if (providerOptions == null) {
    return base.copyWith(appendSystemPrompt: appendSystemPrompt, disallowedTools: disallowedTools);
  }
  return HarnessLaunchOptions(
    appendSystemPrompt: appendSystemPrompt,
    disallowedTools: disallowedTools,
    maxTurns: base.maxTurns,
    model: providerOptions.model,
    effort: providerOptions.effort,
    mcpServerUrl: base.mcpServerUrl,
    mcpGatewayToken: base.mcpGatewayToken,
  );
}

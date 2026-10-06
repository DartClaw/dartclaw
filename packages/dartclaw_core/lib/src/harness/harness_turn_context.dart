import 'agent_harness.dart';

/// Stores the trusted host turn identity for context-aware harness callbacks.
mixin HarnessTurnContextStorage on AgentHarness implements HarnessTurnContextSink {
  @override
  HarnessTurnContext? activeTurnContext;

  @override
  void setTurnContext(HarnessTurnContext? context) {
    activeTurnContext = context;
  }
}

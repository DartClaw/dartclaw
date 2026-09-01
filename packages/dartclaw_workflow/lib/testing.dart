/// Test doubles for this package's ports, for use by consuming test suites.
///
/// Deliberately not re-exported by `dartclaw_workflow.dart`: importing this
/// library is an explicit opt-in from a test, and the package's production
/// surface stays free of test-only symbols.
library;

export 'src/testing/fake_git_gateway.dart' show FakeGitGateway;
export 'src/testing/in_memory_definition_source.dart' show InMemoryDefinitionSource;
export 'src/testing/fake_provider_auth_preflight.dart' show FakeProviderAuthPreflight;
export 'src/testing/fake_skill_introspector.dart' show FakeSkillIntrospector;

/// Test doubles for this package's ports, for use by consuming test suites.
///
/// Deliberately not re-exported by `dartclaw_google_chat.dart`: importing this
/// library is an explicit opt-in from a test, and the package's production
/// surface stays free of test-only symbols.
library;

export 'src/testing/fake_google_chat_rest_client.dart' show FakeGoogleChatRestClient;

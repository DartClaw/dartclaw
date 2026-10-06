/// Test doubles for this package's ports, for use by consuming test suites.
///
/// Deliberately not re-exported by `dartclaw_slack.dart`: importing this
/// library is an explicit opt-in from a test, and the package's production
/// surface stays free of test-only symbols.
library;

export 'src/testing/fake_slack_web_api.dart'
    show FakeSlackFile, FakeSlackFileHost, FakeSlackFileRequest, FakeSlackWebApi;
export 'src/testing/fake_socket_mode_server.dart' show FakeSocketModeServer;

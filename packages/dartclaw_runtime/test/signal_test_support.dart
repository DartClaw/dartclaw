import 'dart:io';

import 'package:dartclaw_signal/dartclaw_signal.dart';

/// Shared server-local fake for the Signal [SignalCliManager] sidecar.
///
/// SignalCliManager is owned by `dartclaw_signal`, which `dartclaw_testing` may
/// not depend on, so this fake lives package-local to `dartclaw_runtime` rather
/// than in the testing barrel.
///
/// Lifecycle methods ([start], [stop], [reset]) are no-ops. Health, registration
/// and link-URI responses are configurable via the public mutable fields so
/// tests can flip state mid-flow, and [healthCheckThrows] makes the health probe
/// fail.
class FakeSignalCliManager extends SignalCliManager {
  new({
    this.fakeHealthy = true,
    this.fakeRunning,
    this.fakeWasPaired = false,
    this.fakeRestartCount = 0,
    this.fakeRegistrationState = SignalRegistrationState.unregistered,
    this.fakeLinkUri,
  }) : super(executable: 'signal-cli', phoneNumber: '+15551234567');

  bool fakeHealthy;
  bool? fakeRunning;
  bool fakeWasPaired;
  int fakeRestartCount;
  SignalRegistrationState fakeRegistrationState;
  String? fakeLinkUri;
  int linkUriRequests = 0;
  bool healthCheckThrows = false;
  int healthCheckRequests = 0;

  @override
  bool get isRunning => fakeRunning ?? fakeHealthy;

  @override
  bool get wasPaired => fakeWasPaired;

  @override
  int get restartCount => fakeRestartCount;

  @override
  Future<bool> healthCheck() async {
    healthCheckRequests++;
    if (healthCheckThrows) {
      throw const SocketException(
        'Connection refused (OS Error: Connection refused, errno = 61), address = 127.0.0.1, port = 47000',
      );
    }
    return fakeHealthy;
  }

  @override
  Future<bool> isAccountRegistered() async => fakeRegistrationState == SignalRegistrationState.registered;

  @override
  Future<SignalRegistrationState> registrationState() async => fakeRegistrationState;

  @override
  Future<String?> getLinkDeviceUri({String deviceName = 'DartClaw'}) async {
    linkUriRequests++;
    return fakeLinkUri;
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> reset() async {}
}

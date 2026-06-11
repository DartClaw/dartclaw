import 'dart:io';

import 'package:dartclaw_signal/dartclaw_signal.dart';

/// Shared server-local fake for the Signal [SignalCliManager] sidecar.
///
/// SignalCliManager is owned by `dartclaw_signal`, which `dartclaw_testing` may
/// not depend on, so this fake lives package-local to `dartclaw_server` rather
/// than in the testing barrel.
///
/// Lifecycle methods ([start], [stop], [reset]) are no-ops. Health, registration
/// and link-URI responses are configurable via the public mutable fields so
/// tests can flip state mid-flow. Verification calls are recorded
/// ([smsRequested]/[voiceRequested]/[lastVerifyCode]) and can be made to throw
/// via the `*Throws` flags.
class FakeSignalCliManager extends SignalCliManager {
  FakeSignalCliManager({this.fakeHealthy = true, this.fakeRegistered = false, this.fakeLinkUri})
    : super(executable: 'signal-cli', phoneNumber: '+15551234567');

  bool fakeHealthy;
  bool fakeRegistered;
  String? fakeLinkUri;
  bool smsRequested = false;
  bool voiceRequested = false;
  String? lastVerifyCode;
  bool verifyThrows = false;
  bool smsThrows = false;
  bool voiceThrows = false;
  bool healthCheckThrows = false;

  @override
  bool get isRunning => fakeHealthy;

  @override
  Future<bool> healthCheck() async {
    if (healthCheckThrows) {
      throw const SocketException(
        'Connection refused (OS Error: Connection refused, errno = 61), address = 127.0.0.1, port = 47000',
      );
    }
    return fakeHealthy;
  }

  @override
  Future<bool> isAccountRegistered() async => fakeRegistered;

  @override
  Future<String?> getLinkDeviceUri({String deviceName = 'DartClaw'}) async => fakeLinkUri;

  @override
  Future<void> requestSmsVerification({String? phone, String? captcha}) async {
    if (smsThrows) throw Exception('SMS send failed');
    smsRequested = true;
  }

  @override
  Future<void> requestVoiceVerification({String? phone, String? captcha}) async {
    if (voiceThrows) throw Exception('Voice call failed');
    voiceRequested = true;
  }

  @override
  Future<void> verifySmsCode(String code, {String? phone}) async {
    lastVerifyCode = code;
    if (verifyThrows) throw Exception('Invalid code');
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> reset() async {}
}

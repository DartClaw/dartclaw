import 'dart:async';

import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';

/// Shared server-local fake for the WhatsApp [GowaManager] sidecar.
///
/// GowaManager is owned by `dartclaw_whatsapp`, which `dartclaw_testing` may
/// not depend on, so this fake lives package-local to `dartclaw_server` rather
/// than in the testing barrel.
///
/// Lifecycle methods ([start], [stop], [reset]) are no-ops. Outbound messages
/// are recorded in [sentTexts]/[sentMedia]; [firstSent] completes on the first
/// [sendText]/[sendMedia]. Status and running/paired state are configurable so
/// each call site can reproduce its own permutation.
class FakeGowaManager extends GowaManager {
  FakeGowaManager({
    bool? running,
    GowaStatus status = (isConnected: false, isLoggedIn: false, deviceId: null),
    String? pairedJid,
    GowaLoginQr loginQrValue = (url: null, durationSeconds: 60),
  }) : _running = running,
       _status = status,
       _pairedJid = pairedJid,
       _loginQr = loginQrValue,
       super(executable: '', host: '', port: 0, webhookUrl: '', osName: '');

  final bool? _running;
  final GowaStatus _status;
  final String? _pairedJid;
  final GowaLoginQr _loginQr;

  final List<(String, String)> sentTexts = [];
  final List<(String, String)> sentMedia = [];
  final _firstSentCompleter = Completer<void>();

  /// Completes when the first outbound message is sent.
  Future<void> get firstSent => _firstSentCompleter.future;

  @override
  bool get isRunning => _running ?? super.isRunning;

  @override
  String? get pairedJid => _pairedJid;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> reset() async {}

  @override
  Future<void> sendText(String jid, String text) async {
    sentTexts.add((jid, text));
    if (!_firstSentCompleter.isCompleted) _firstSentCompleter.complete();
  }

  @override
  Future<void> sendMedia(String jid, String filePath, {String? caption}) async {
    sentMedia.add((jid, filePath));
  }

  @override
  Future<GowaStatus> status() async => _status;

  @override
  Future<GowaLoginQr> loginQr() async => _loginQr;
}

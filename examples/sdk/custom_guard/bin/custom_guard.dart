// ignore_for_file: avoid_print

import 'package:dartclaw/dartclaw.dart';

const _secretPhrase = 'swordfish';

Future<void> main(List<String> args) async {
  final input = args.isEmpty ? 'please keep this public' : args.join(' ');
  final chain = GuardChain(
    guards: [SecretPhraseGuard(secretPhrase: _secretPhrase)],
    onVerdict: (guardName, category, verdict, message, context) {
      print('audit guard=$guardName category=$category hook=${context.hookPoint} verdict=$verdict reason=$message');
    },
  );

  final verdict = await chain.evaluateMessageReceived(input, source: 'cli', sessionId: 'custom-guard-demo');
  switch (verdict) {
    case GuardPass():
      print('pass: "$input"');
    case GuardWarn(:final message):
      print('warn: $message');
    case GuardBlock(:final message):
      print('block: $message');
  }
}

final class SecretPhraseGuard extends Guard {
  SecretPhraseGuard({required this.secretPhrase});

  final String secretPhrase;

  @override
  String get name => 'secret_phrase_guard';

  @override
  String get category => 'content';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    if (context.hookPoint != 'messageReceived') return GuardVerdict.pass();
    final content = context.messageContent?.toLowerCase() ?? '';
    if (content.contains(secretPhrase.toLowerCase())) {
      return GuardVerdict.block('message contains a protected phrase');
    }
    return GuardVerdict.pass();
  }
}

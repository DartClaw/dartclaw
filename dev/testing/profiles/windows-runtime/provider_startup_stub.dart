import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--version') {
    stdout.writeln('dartclaw-provider-startup-stub 1.0.0');
    return;
  }
  if (arguments.length == 2 && arguments[0] == 'auth' && arguments[1] == 'status') {
    stdout.writeln(jsonEncode({'loggedIn': true, 'authMethod': 'smoke-stub'}));
    return;
  }

  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final message = jsonDecode(line);
    if (message is! Map<String, dynamic> ||
        message['type'] != 'control_request' ||
        message['request'] is! Map ||
        (message['request'] as Map)['subtype'] != 'initialize') {
      continue;
    }
    stdout.writeln(
      jsonEncode({
        'type': 'control_response',
        'response': {'subtype': 'success', 'request_id': message['request_id'], 'response': <String, dynamic>{}},
      }),
    );
    await stdout.flush();
  }
}

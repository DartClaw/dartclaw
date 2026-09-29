import 'package:dartclaw_core/dartclaw_core.dart';

Future<void> main(List<String> args) async {
  final store = await FileExecutionStore.open(args[0]);
  try {
    for (var index = 0; index < 10; index++) {
      await store.update((state) {
        (state['goals'] as Map<String, dynamic>)['${args[1]}-$index'] = {'id': '${args[1]}-$index'};
      });
    }
  } finally {
    await store.close();
  }
}

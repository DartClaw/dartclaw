import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/search_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:dartclaw_search/src/default_embedding_model_acquirer.dart'
    show createDefaultEmbeddingModelAcquirerForTesting;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late DartclawConfig config;
  late List<String> output;
  late HttpServer server;
  var requests = 0;
  const contents = 'tiny verified model';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('model_command_');
    config = DartclawConfig(server: ServerConfig(dataDir: directory.path));
    output = [];
    requests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      request.response.add(utf8.encode(contents));
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  for (final reused in [false, true]) {
    test(
      'acquisition ${reused ? 'reuses verified offline bytes' : 'publishes verified bytes'} at managed path',
      () async {
        final target = File(p.join(directory.path, 'models', DefaultEmbeddingModel.filename));
        if (reused) {
          await target.parent.create(recursive: true);
          await target.writeAsString(contents);
        }
        final acquirer = createDefaultEmbeddingModelAcquirerForTesting(
          source: Uri.parse('http://127.0.0.1:${server.port}/model'),
          expectedSize: utf8.encode(contents).length,
          expectedSha256: '61c1b462200281b42b6b32dcba5fd36d75dc54ddbfcfd6780852af9f43513530',
          checkNetworkAccess: (_) async {},
          httpClientFactory: HttpClient.new,
        );
        final runner = DartclawRunner()
          ..addCommand(
            SearchCommand(
              downloadModel: SearchDownloadModelCommand(
                config: config,
                writeLine: output.add,
                acquireModel: acquirer.acquire,
              ),
            ),
          );

        await runner.run(['search', 'download-model', '--json']);

        expect(jsonDecode(output.single), {
          'status': reused ? 'reused' : 'downloaded',
          'path': target.path,
          'model': DefaultEmbeddingModel.filename,
          'license': DefaultEmbeddingModel.licenseName,
          'licenseUrl': DefaultEmbeddingModel.licenseUrl,
        });
        expect(await target.readAsString(), contents);
        expect(requests, reused ? 0 : 1);
      },
    );
  }

  test('acquisition failure reports recovery without leaking boundary error content', () async {
    int? exitCode;
    final runner = DartclawRunner()
      ..addCommand(
        SearchCommand(
          downloadModel: SearchDownloadModelCommand(
            config: config,
            writeLine: output.add,
            exitFn: (code) => exitCode = code,
            acquireModel: ({required destinationPath}) async => throw const HttpException('credential=secret'),
          ),
        ),
      );

    await runner.run(['search', 'download-model', '--json']);

    expect(exitCode, 1);
    final result = jsonDecode(output.single) as Map<String, dynamic>;
    expect(result.keys, ['error']);
    expect(result['error'], contains('dartclaw search download-model'));
    expect(output.join(), isNot(contains('secret')));
    expect(requests, 0);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show checkEmbeddingNetworkAccess, defaultEmbeddingModelPath;
import 'package:dartclaw_search/dartclaw_search.dart';

import 'config_loader.dart';
import 'search_inspect_command.dart';

class SearchCommand extends Command<void> {
  new({SearchDownloadModelCommand? downloadModel, SearchInspectCommand? inspect}) {
    addSubcommand(inspect ?? SearchInspectCommand());
    addSubcommand(downloadModel ?? SearchDownloadModelCommand());
  }

  @override
  String get name => 'search';

  @override
  String get description => 'Manage and inspect local search';
}

class SearchDownloadModelCommand extends Command<void> {
  new({
    DartclawConfig? config,
    void Function(String)? writeLine,
    void Function(int)? exitFn,
    Future<ModelAcquisitionResult> Function({required String destinationPath})? acquireModel,
  }) : _config = config,
       _writeLine = writeLine ?? stdout.writeln,
       _exitFn = exitFn ?? exit,
       _acquireModel = acquireModel {
    argParser.addFlag('json', negatable: false, help: 'Output the verified model result as JSON');
  }

  final DartclawConfig? _config;
  final void Function(String) _writeLine;
  final void Function(int) _exitFn;
  final Future<ModelAcquisitionResult> Function({required String destinationPath})? _acquireModel;

  @override
  String get name => 'download-model';

  @override
  String get description => 'Download and verify the supported local embedding model';

  @override
  Future<void> run() async {
    final config = _config ?? loadCliConfig(configPath: globalResults?['config'] as String?);
    final json = argResults?['json'] as bool? ?? false;
    final acquire =
        _acquireModel ?? DefaultEmbeddingModelAcquirer(checkNetworkAccess: checkEmbeddingNetworkAccess).acquire;
    try {
      final result = await acquire(destinationPath: defaultEmbeddingModelPath(config));
      if (json) {
        _writeLine(
          jsonEncode({
            'status': result.status.name,
            'path': result.path,
            'model': DefaultEmbeddingModel.filename,
            'license': DefaultEmbeddingModel.licenseName,
            'licenseUrl': DefaultEmbeddingModel.licenseUrl,
          }),
        );
      } else {
        _writeLine(
          '${result.status == ModelAcquisitionStatus.reused ? 'Reused' : 'Downloaded'} verified model: ${result.path}',
        );
        _writeLine('${DefaultEmbeddingModel.licenseName}: ${DefaultEmbeddingModel.licenseUrl}');
      }
    } on Exception {
      const message =
          'Model acquisition failed. Retry dartclaw search download-model after checking network access and disk space.';
      _writeLine(json ? jsonEncode({'error': message}) : message);
      _exitFn(1);
    }
  }
}

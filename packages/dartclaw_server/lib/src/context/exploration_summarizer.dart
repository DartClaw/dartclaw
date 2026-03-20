import 'dart:convert';

import 'result_trimmer.dart';
import 'summary/csv_summarizer.dart';
import 'summary/json_summarizer.dart';
import 'summary/source_code_summarizer.dart';
import 'type_detector.dart';

/// Produces type-aware structural summaries for large tool output.
///
/// When content exceeds [thresholdTokens], detects the content type and
/// produces a deterministic structural summary. Falls back to [ResultTrimmer]
/// head+tail truncation for unrecognized types or parse failures.
class ExplorationSummarizer {
  final ResultTrimmer _trimmer;

  /// Token threshold above which structural summarization is attempted.
  final int thresholdTokens;

  const ExplorationSummarizer({ResultTrimmer trimmer = const ResultTrimmer(), this.thresholdTokens = 25000})
    : _trimmer = trimmer;

  /// Summarize [content] if it exceeds the token threshold, otherwise
  /// apply the byte-cap trim from [ResultTrimmer].
  ///
  /// Content below [thresholdTokens] still passes through
  /// [ResultTrimmer.trim] to preserve the existing byte-cap safeguard.
  ///
  /// [fileHint] is an optional file path used for extension-based type
  /// detection. When null, content heuristics are used.
  String summarizeOrTrim(String content, {String? fileHint}) {
    final estimatedTokens = _estimateTokens(content);
    if (estimatedTokens <= thresholdTokens) return _trimmer.trim(content);

    final type = TypeDetector.detect(content, fileHint: fileHint);
    if (type == null) return _trimmer.trim(content);

    try {
      final summary = _summarize(content, type, estimatedTokens);
      return summary ?? _trimmer.trim(content);
    } on Exception catch (_) {
      return _trimmer.trim(content);
    }
  }

  String? _summarize(String content, ContentType type, int estimatedTokens) {
    return switch (type) {
      ContentType.json => JsonSummarizer.summarize(content, estimatedTokens),
      ContentType.yaml => JsonSummarizer.summarize(content, estimatedTokens, isYaml: true),
      ContentType.csv => CsvSummarizer.summarize(content, estimatedTokens),
      ContentType.tsv => CsvSummarizer.summarize(content, estimatedTokens, delimiter: '\t'),
      ContentType.dart ||
      ContentType.typescript ||
      ContentType.python ||
      ContentType.go => SourceCodeSummarizer.summarize(content, type, estimatedTokens),
    };
  }

  static int _estimateTokens(String content) {
    return utf8.encode(content).length ~/ 4;
  }
}

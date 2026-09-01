import 'package:dartclaw_core/dartclaw_core.dart';

import 'markdown_converter.dart';

/// Format agent output into a list of ChannelResponses ready for sending.
///
/// Applies the identity prefix, converts Markdown, and chunks the text.
List<ChannelResponse> formatResponse(
  String agentOutput, {
  required String model,
  required String agentName,
  required int maxChunkSize,
}) {
  final formattedText = markdownToWhatsApp(agentOutput);

  // Apply prefix to first chunk
  final prefix = '*$model* — _${agentName}_\n\n';

  // Chunk text (account for prefix in first chunk)
  final textChunks = chunkNativeChatMarkup(formattedText, maxSize: maxChunkSize - prefix.length);
  if (textChunks.isEmpty) return [];

  final responses = <ChannelResponse>[];

  responses.add(ChannelResponse(text: '$prefix${textChunks.first}'));

  // Subsequent chunks: text only
  for (var i = 1; i < textChunks.length; i++) {
    responses.add(ChannelResponse(text: textChunks[i]));
  }

  return responses;
}

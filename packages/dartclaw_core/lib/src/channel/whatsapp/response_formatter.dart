import '../channel.dart';
import 'media_extractor.dart';
import 'text_chunking.dart';

/// Format agent output into a list of ChannelResponses ready for sending.
///
/// Steps: extract media -> apply prefix -> chunk text -> assemble responses.
List<ChannelResponse> formatResponse(
  String agentOutput, {
  required String model,
  required String agentName,
  required int maxChunkSize,
  required String workspaceDir,
}) {
  // Extract MEDIA:<path> directives
  final extraction = extractMediaDirectives(agentOutput, workspaceDir: workspaceDir);

  // Apply prefix to first chunk
  final prefix = '*$model* — _${agentName}_\n\n';

  // Chunk text (account for prefix in first chunk)
  final textChunks = chunkText(extraction.cleanedText, maxSize: maxChunkSize - prefix.length);
  if (textChunks.isEmpty) return [];

  final responses = <ChannelResponse>[];

  // First chunk gets prefix + media attachments
  responses.add(ChannelResponse(text: '$prefix${textChunks.first}', mediaAttachments: extraction.mediaPaths));

  // Subsequent chunks: text only
  for (var i = 1; i < textChunks.length; i++) {
    responses.add(ChannelResponse(text: textChunks[i]));
  }

  return responses;
}

import 'package:dartclaw_core/dartclaw_core.dart' show ChannelAttachment;
import 'package:logging/logging.dart';

import 'slack_markdown.dart';
import 'slack_web_api_client.dart';

const _maxFileBytes = 20 * 1024 * 1024;
const _maxFilesPerMessage = 5;
const _maxNameChars = 80;

/// What one message's files came to: the ones fetched, and a line per file that was not.
typedef SlackFileIntake = ({List<ChannelAttachment> attachments, List<String> problems});

/// Downloads the files of an admitted message, within 20 MB per file and 5 per message.
///
/// A file that is refused or fails is named in `problems` with its reason, never
/// with its URL, and never stops the others or the message text. Files are taken in
/// the order Slack lists them; every file past the fifth is refused.
Future<SlackFileIntake> takeSlackFiles(SlackWebApiClient api, List<Map<String, dynamic>> files) async {
  final log = Logger('SlackFileIntake');
  final attachments = <ChannelAttachment>[];
  final problems = <String>[];
  for (final (index, file) in files.indexed) {
    final label = _label(file);
    if (index >= _maxFilesPerMessage) {
      problems.add('$label: over the limit of $_maxFilesPerMessage files per message');
      continue;
    }
    if (file['file_access'] == 'check_file_info') {
      problems.add('$label: shared from another Slack workspace, which Slack does not hand over');
      continue;
    }
    final url = switch (file['url_private_download'] ?? file['url_private']) {
      final String value when value.isNotEmpty => Uri.tryParse(value),
      _ => null,
    };
    if (url == null) {
      problems.add('$label: hosted outside Slack, so there is nothing to download');
      continue;
    }
    if (file['size'] case final int size when size > _maxFileBytes) {
      problems.add('$label: larger than the 20 MB limit per file');
      continue;
    }

    final mediaType = switch (file['mimetype']) {
      final String value when value.isNotEmpty => value,
      _ => 'application/octet-stream',
    };
    try {
      final bytes = await api.downloadFile(url, maxBytes: _maxFileBytes, declaredMediaType: mediaType);
      if (bytes.isEmpty) {
        problems.add('$label: the file is empty');
        continue;
      }
      attachments.add(ChannelAttachment(filename: _name(file), mediaType: mediaType, bytes: bytes));
    } on SlackApiException catch (error) {
      log.warning('Could not fetch a Slack file: $error');
      problems.add('$label: ${_reason(error)}');
    }
  }
  return (attachments: attachments, problems: problems);
}

String _reason(SlackApiException error) => switch (error.errorCode) {
  slackFileTooLarge => 'larger than the 20 MB limit per file',
  slackFileScopeMissing => 'Slack answered with a web page instead of the file, so the app needs the files:read scope',
  _ when error.statusCode != null => 'Slack refused the download (HTTP ${error.statusCode})',
  _ => 'the download failed',
};

/// The file's name as the attachment carries it; a name Slack omits falls back to the file ID.
String _name(Map<String, dynamic> file) => switch (file['name'] ?? file['title']) {
  final String name when name.trim().isNotEmpty => name.trim(),
  _ => switch (file['id']) {
    final String id when id.isNotEmpty => id,
    _ => 'file',
  },
};

/// A name safe to put in a reply: one line, bounded, with no markup a stranger's file name could use to ping.
String _label(Map<String, dynamic> file) {
  var name = _name(file).replaceAll(RegExp(r'\s+'), ' ').replaceAll('`', "'");
  if (name.length > _maxNameChars) name = '${name.substring(0, _maxNameChars)}...';
  return '`${escapeSlackMarkdown(name)}`';
}

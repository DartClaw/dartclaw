import 'dart:convert';

/// Maximum task description length before a card body is truncated.
const cardDescriptionMaxLength = 2000;

/// Purpose-built Google Chat Cards v2 builder for DartClaw notifications.
class ChatCardBuilder {
  const ChatCardBuilder();

  /// Builds a task notification card.
  Map<String, dynamic> taskNotification({
    required String taskId,
    required String title,
    required String status,
    String? description,
    String? errorSummary,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool includeReviewButtons = false,
  }) {
    final sections = <Map<String, dynamic>>[_statusBadgeSection(status)];

    final trimmedDescription = description?.trim();
    if (trimmedDescription != null && trimmedDescription.isNotEmpty) {
      sections.add({
        'widgets': [
          {
            'textParagraph': {'text': _escapeAndTruncateDescription(trimmedDescription)},
          },
        ],
      });
    }

    final trimmedErrorSummary = errorSummary?.trim();
    if ((status == 'failed' || status == 'error') && trimmedErrorSummary != null && trimmedErrorSummary.isNotEmpty) {
      sections.add({
        'widgets': [
          {
            'textParagraph': {'text': _escapeText(trimmedErrorSummary)},
          },
        ],
      });
    }

    final timestampWidgets = <Map<String, dynamic>>[];
    if (createdAt != null) {
      timestampWidgets.add({
        'decoratedText': {'topLabel': 'Created', 'text': _formatTimestamp(createdAt)},
      });
    }
    if (updatedAt != null) {
      timestampWidgets.add({
        'decoratedText': {'topLabel': 'Updated', 'text': _formatTimestamp(updatedAt)},
      });
    }
    if (timestampWidgets.isNotEmpty) {
      sections.add({'widgets': timestampWidgets});
    }

    if (includeReviewButtons) {
      sections.add(_reviewButtonsSection(taskId));
    }

    return _wrapCard(
      cardId: 'task_$taskId',
      header: {'title': title, 'subtitle': _statusLabel(status)},
      sections: sections,
    );
  }

  /// Builds an error notification card.
  Map<String, dynamic> errorNotification({
    required String title,
    required String errorSummary,
    String? taskId,
    String? sessionId,
  }) {
    final sections = <Map<String, dynamic>>[
      {
        'widgets': [
          {
            'textParagraph': {'text': _escapeText(errorSummary.trim())},
          },
        ],
      },
    ];

    final referenceWidgets = <Map<String, dynamic>>[];
    if (taskId != null && taskId.isNotEmpty) {
      referenceWidgets.add({
        'decoratedText': {'topLabel': 'Task ID', 'text': _escapeText(taskId)},
      });
    }
    if (sessionId != null && sessionId.isNotEmpty) {
      referenceWidgets.add({
        'decoratedText': {'topLabel': 'Session ID', 'text': _escapeText(sessionId)},
      });
    }
    if (referenceWidgets.isNotEmpty) {
      sections.add({'widgets': referenceWidgets});
    }

    return _wrapCard(
      cardId: 'error_${taskId ?? 'notification'}',
      header: {'title': title, 'subtitle': 'Error'},
      sections: sections,
    );
  }

  /// Builds a simple confirmation card.
  Map<String, dynamic> confirmationCard({required String title, required String message}) {
    return _wrapCard(
      cardId: 'confirmation',
      header: {'title': title, 'subtitle': 'Confirmation'},
      sections: [
        {
          'widgets': [
            {
              'textParagraph': {'text': _escapeText(message.trim())},
            },
          ],
        },
      ],
    );
  }

  Map<String, dynamic> _wrapCard({
    required String cardId,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> sections,
  }) {
    return {
      'cardsV2': [
        {
          'cardId': cardId,
          'card': {'header': header, 'sections': sections},
        },
      ],
    };
  }

  Map<String, dynamic> _reviewButtonsSection(String taskId) {
    return {
      'widgets': [
        {
          'buttonList': {
            'buttons': [
              _actionButton(
                text: 'Accept',
                function: 'task_accept',
                taskId: taskId,
                color: const {'red': 0.13, 'green': 0.59, 'blue': 0.33, 'alpha': 1.0},
              ),
              _actionButton(
                text: 'Reject',
                function: 'task_reject',
                taskId: taskId,
                color: const {'red': 0.84, 'green': 0.18, 'blue': 0.18, 'alpha': 1.0},
              ),
            ],
          },
        },
      ],
    };
  }

  Map<String, dynamic> _statusBadgeSection(String status) {
    final color = _statusColor(status);
    final label = _escapeText(_statusLabel(status));
    return {
      'widgets': [
        {
          'decoratedText': {
            'topLabel': 'Status',
            'text': color == null ? '<b>$label</b>' : '<font color="$color"><b>$label</b></font>',
            'wrapText': true,
          },
        },
      ],
    };
  }

  Map<String, dynamic> _actionButton({
    required String text,
    required String function,
    required String taskId,
    required Map<String, double> color,
  }) {
    return {
      'text': text,
      'onClick': {
        'action': {
          'function': function,
          'parameters': [
            {'key': 'taskId', 'value': taskId},
          ],
        },
      },
      'color': color,
    };
  }

  String _escapeAndTruncateDescription(String description) {
    final escapedSegments = <String>[for (final rune in description.runes) _escapeText(String.fromCharCode(rune))];
    final escapedLength = escapedSegments.fold<int>(0, (total, segment) => total + segment.length);
    if (escapedLength <= cardDescriptionMaxLength) {
      return escapedSegments.join();
    }

    final maxContentLength = cardDescriptionMaxLength - 3;
    final buffer = StringBuffer();
    var truncatedLength = 0;
    for (final escapedSegment in escapedSegments) {
      if (truncatedLength + escapedSegment.length > maxContentLength) {
        break;
      }
      buffer.write(escapedSegment);
      truncatedLength += escapedSegment.length;
    }
    return '${buffer.toString()}...';
  }

  String _statusLabel(String status) => switch (status) {
    'running' => 'Running',
    'review' => 'Needs Review',
    'accepted' => 'Accepted',
    'rejected' => 'Rejected',
    'failed' => 'Failed',
    'error' => 'Error',
    _ => status,
  };

  String? _statusColor(String status) => switch (status) {
    'running' => '#1a73e8',
    'review' => '#f9ab00',
    'accepted' => '#1e8e3e',
    'rejected' => '#d93025',
    'failed' => '#d93025',
    'error' => '#d93025',
    _ => null,
  };

  String _formatTimestamp(DateTime timestamp) {
    final utc = timestamp.toUtc();
    return '${utc.year}-${_pad(utc.month)}-${_pad(utc.day)} '
        '${_pad(utc.hour)}:${_pad(utc.minute)} UTC';
  }

  String _pad(int value) => value.toString().padLeft(2, '0');

  String _escapeText(String value) {
    return const HtmlEscape(HtmlEscapeMode.element).convert(value).replaceAll('\n', '<br>');
  }
}

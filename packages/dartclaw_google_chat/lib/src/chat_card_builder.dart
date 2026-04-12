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
    String? requestedBy,
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
    final trimmedRequestedBy = requestedBy?.trim();
    if (trimmedRequestedBy != null && trimmedRequestedBy.isNotEmpty) {
      timestampWidgets.add({
        'decoratedText': {'topLabel': 'Requested by', 'text': _escapeText(trimmedRequestedBy)},
      });
    }
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

  /// Builds a severity-colored alert notification card.
  ///
  /// [severity] must be `'info'`, `'warning'`, or `'critical'`. Unrecognized
  /// values fall back to no color (plain bold label).
  ///
  /// Severity colors: critical → `#d93025` (red), warning → `#f9ab00` (amber),
  /// info → `#1a73e8` (blue). These match existing [_statusColor] values.
  Map<String, dynamic> alertNotification({
    required String title,
    required String severity,
    required String body,
    Map<String, String>? details,
  }) {
    final color = _alertSeverityColor(severity);
    final severityLabel = _escapeText(_alertSeverityLabel(severity));
    final sections = <Map<String, dynamic>>[
      {
        'widgets': [
          {
            'decoratedText': {
              'topLabel': 'Severity',
              'text': color == null ? '<b>$severityLabel</b>' : '<font color="$color"><b>$severityLabel</b></font>',
              'wrapText': true,
            },
          },
        ],
      },
      {
        'widgets': [
          {
            'textParagraph': {'text': _escapeText(body.trim())},
          },
        ],
      },
    ];

    if (details != null && details.isNotEmpty) {
      sections.add({
        'widgets': [
          for (final entry in details.entries)
            {
              'decoratedText': {'topLabel': _escapeText(entry.key), 'text': _escapeText(entry.value)},
            },
        ],
      });
    }

    return _wrapCard(
      cardId: 'alert_${severity}_${title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_')}',
      header: {'title': _escapeText(title), 'subtitle': _escapeText(_alertSeverityLabel(severity))},
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

  /// Builds an advisor insight card.
  Map<String, dynamic> advisorInsight({
    required String status,
    required String observation,
    String? suggestion,
    String? triggerType,
  }) {
    final sections = <Map<String, dynamic>>[
      {
        'widgets': [
          {
            'decoratedText': {
              'topLabel': 'Status',
              'text':
                  '<font color="${_advisorStatusColor(status)}"><b>${_escapeText(_advisorStatusLabel(status))}</b></font>',
              'wrapText': true,
            },
          },
          {
            'textParagraph': {'text': _escapeText(observation.trim())},
          },
        ],
      },
    ];

    final trimmedSuggestion = suggestion?.trim();
    if (trimmedSuggestion != null && trimmedSuggestion.isNotEmpty) {
      sections.add({
        'widgets': [
          {
            'decoratedText': {'topLabel': 'Suggestion', 'text': _escapeText(trimmedSuggestion), 'wrapText': true},
          },
        ],
      });
    }

    final trimmedTriggerType = triggerType?.trim();
    if (trimmedTriggerType != null && trimmedTriggerType.isNotEmpty) {
      sections.add({
        'widgets': [
          {
            'decoratedText': {'topLabel': 'Trigger', 'text': _escapeText(trimmedTriggerType), 'wrapText': true},
          },
        ],
      });
    }

    return _wrapCard(
      cardId: 'advisor_insight',
      header: {'title': 'Advisor Insight', 'subtitle': _advisorStatusLabel(status)},
      sections: sections,
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

  String _alertSeverityLabel(String severity) => switch (severity) {
    'critical' => 'Critical',
    'warning' => 'Warning',
    'info' => 'Info',
    _ => severity,
  };

  String? _alertSeverityColor(String severity) => switch (severity) {
    'critical' => '#d93025',
    'warning' => '#f9ab00',
    'info' => '#1a73e8',
    _ => null,
  };

  String _advisorStatusLabel(String status) => switch (status) {
    'on_track' => 'On Track',
    'diverging' => 'Diverging',
    'stuck' => 'Stuck',
    'concerning' => 'Concerning',
    _ => status,
  };

  String _advisorStatusColor(String status) => switch (status) {
    'on_track' => '#1e8e3e',
    'diverging' => '#f9ab00',
    'stuck' => '#d93025',
    'concerning' => '#a142f4',
    _ => '#5f6368',
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

import 'dart:convert';

import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Encodes a CloudEvent JSON map to a base64 string (matching Pub/Sub format).
String encodeCloudEvent(Map<String, dynamic> cloudEvent) {
  return base64.encode(utf8.encode(jsonEncode(cloudEvent)));
}

/// Creates a sample `message.v1.created` CloudEvent payload.
Map<String, dynamic> sampleCreatedEvent({
  String senderName = 'users/123456',
  String senderType = 'HUMAN',
  String? senderDisplayName = 'Alice Smith',
  String spaceName = 'spaces/SPACE_ABC',
  String spaceType = 'SPACE',
  String messageName = 'spaces/SPACE_ABC/messages/MSG_001',
  String text = 'Hello world',
  String? argumentText,
  String createTime = '2024-03-15T10:30:00.260127Z',
  String cloudEventId = 'evt-uuid-1234',
}) => {
  'id': cloudEventId,
  'source': '//chat.googleapis.com/$spaceName',
  'subject': messageName,
  'type': 'google.workspace.chat.message.v1.created',
  'specversion': '1.0',
  'time': '2024-03-15T10:30:00Z',
  'datacontenttype': 'application/json',
  'data': {
    'message': {
      'name': messageName,
      'sender': {'name': senderName, 'type': senderType, 'displayName': ?senderDisplayName},
      'createTime': createTime,
      'text': text,
      'argumentText': ?argumentText,
      'space': {'name': spaceName, 'type': spaceType},
    },
  },
};

/// Creates a sample `batchCreated` CloudEvent payload with the given messages.
Map<String, dynamic> sampleBatchCreatedEvent({
  required List<Map<String, dynamic>> messageResources,
  String cloudEventId = 'evt-batch-1234',
}) => {
  'id': cloudEventId,
  'type': 'google.workspace.chat.message.v1.batchCreated',
  'specversion': '1.0',
  'time': '2024-03-15T10:30:00Z',
  'datacontenttype': 'application/json',
  'data': {
    'messages': [
      for (final msg in messageResources) {'message': msg},
    ],
  },
};

/// Creates a sample message resource (inner part of a CloudEvent).
Map<String, dynamic> sampleMessageResource({
  String senderName = 'users/123456',
  String senderType = 'HUMAN',
  String? senderDisplayName = 'Alice Smith',
  String spaceName = 'spaces/SPACE_ABC',
  String spaceType = 'SPACE',
  String messageName = 'spaces/SPACE_ABC/messages/MSG_001',
  String text = 'Hello world',
  String createTime = '2024-03-15T10:30:00.260127Z',
}) => {
  'name': messageName,
  'sender': {'name': senderName, 'type': senderType, 'displayName': ?senderDisplayName},
  'createTime': createTime,
  'text': text,
  'space': {'name': spaceName, 'type': spaceType},
};

/// Creates a [ReceivedMessage] from a CloudEvent map.
ReceivedMessage receivedMessageFrom(
  Map<String, dynamic> cloudEvent, {
  String ackId = 'ack-1',
  String messageId = 'pubsub-msg-1',
  String publishTime = '2024-03-15T10:30:00.260Z',
}) => ReceivedMessage(
  ackId: ackId,
  data: encodeCloudEvent(cloudEvent),
  messageId: messageId,
  publishTime: publishTime,
  attributes: {if (cloudEvent['type'] case final String type) 'ce-type': type},
);

/// Creates a [ReceivedMessage] in CloudEvents Pub/Sub binding format.
///
/// Metadata lives in Pub/Sub attributes (`ce-type`, `ce-id`, ...) while the
/// message body contains only the CloudEvent `data` payload.
ReceivedMessage receivedMessageFromPubSubBinding(
  Map<String, dynamic> cloudEvent, {
  String ackId = 'ack-1',
  String messageId = 'pubsub-msg-1',
  String publishTime = '2024-03-15T10:30:00.260Z',
}) => ReceivedMessage(
  ackId: ackId,
  data: encodeCloudEvent(cloudEvent['data'] as Map<String, dynamic>),
  messageId: messageId,
  publishTime: publishTime,
  attributes: {
    if (cloudEvent['id'] case final String id) 'ce-id': id,
    if (cloudEvent['source'] case final String source) 'ce-source': source,
    if (cloudEvent['subject'] case final String subject) 'ce-subject': subject,
    if (cloudEvent['type'] case final String type) 'ce-type': type,
    if (cloudEvent['specversion'] case final String specversion) 'ce-specversion': specversion,
    if (cloudEvent['time'] case final String time) 'ce-time': time,
  },
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('CloudEventAdapter', () {
    group('message.v1.created', () {
      test('parses standard created event into ChannelMessage', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(receivedMessageFrom(sampleCreatedEvent()));

        expect(result, isA<MessageResult>());
        final messages = (result as MessageResult).messages;
        expect(messages, hasLength(1));

        final msg = messages.first;
        expect(msg.channelType, ChannelType.googlechat);
        expect(msg.senderJid, 'users/123456');
        expect(msg.groupJid, 'spaces/SPACE_ABC');
        expect(msg.text, 'Hello world');
        expect(msg.metadata['spaceName'], 'spaces/SPACE_ABC');
        expect(msg.metadata['spaceType'], 'SPACE');
        expect(msg.metadata['senderDisplayName'], 'Alice Smith');
        expect(msg.metadata['messageName'], 'spaces/SPACE_ABC/messages/MSG_001');
      });

      test('parses Pub/Sub CloudEvents binding format', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(receivedMessageFromPubSubBinding(sampleCreatedEvent()));

        expect(result, isA<MessageResult>());
        final msg = (result as MessageResult).messages.first;
        expect(msg.senderJid, 'users/123456');
        expect(msg.groupJid, 'spaces/SPACE_ABC');
        expect(msg.text, 'Hello world');
        expect(msg.metadata['messageName'], 'spaces/SPACE_ABC/messages/MSG_001');
      });

      test('uses argumentText when present', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(
          receivedMessageFrom(sampleCreatedEvent(text: '@Bot stripped text', argumentText: 'stripped text')),
        );
        expect(result, isA<MessageResult>());
        expect((result as MessageResult).messages.first.text, 'stripped text');
      });

      test('falls back to text when argumentText is absent', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(receivedMessageFrom(sampleCreatedEvent()));
        expect(result, isA<MessageResult>());
        expect((result as MessageResult).messages.first.text, 'Hello world');
      });

      test('falls back to text when argumentText is empty whitespace', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(receivedMessageFrom(sampleCreatedEvent(argumentText: '  ')));
        expect(result, isA<MessageResult>());
        expect((result as MessageResult).messages.first.text, 'Hello world');
      });

      test('sets groupJid to null for DM spaces', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(receivedMessageFrom(sampleCreatedEvent(spaceType: 'DM')));
        expect(result, isA<MessageResult>());
        expect((result as MessageResult).messages.first.groupJid, isNull);
      });

      test('sets groupJid for ROOM space type', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(receivedMessageFrom(sampleCreatedEvent(spaceType: 'ROOM')));
        expect(result, isA<MessageResult>());
        expect((result as MessageResult).messages.first.groupJid, 'spaces/SPACE_ABC');
      });

      test('defaults to group for unknown space type', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(receivedMessageFrom(sampleCreatedEvent(spaceType: 'UNKNOWN_TYPE')));
        expect(result, isA<MessageResult>());
        expect((result as MessageResult).messages.first.groupJid, 'spaces/SPACE_ABC');
      });

      test('parses createTime as timestamp', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(
          receivedMessageFrom(sampleCreatedEvent(createTime: '2024-03-15T10:30:00.260127Z')),
        );
        expect(result, isA<MessageResult>());
        final ts = (result as MessageResult).messages.first.timestamp;
        expect(ts.year, 2024);
        expect(ts.month, 3);
        expect(ts.day, 15);
        expect(ts.hour, 10);
        expect(ts.minute, 30);
      });

      test('stores createTime in metadata as messageCreateTime', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(
          receivedMessageFrom(sampleCreatedEvent(createTime: '2024-03-15T10:30:00.260127Z')),
        );

        expect(result, isA<MessageResult>());
        expect(
          (result as MessageResult).messages.first.metadata['messageCreateTime'],
          '2024-03-15T10:30:00.260127Z',
        );
      });

      test('uses message name as id', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(
          receivedMessageFrom(sampleCreatedEvent(messageName: 'spaces/S/messages/M')),
        );
        expect(result, isA<MessageResult>());
        expect((result as MessageResult).messages.first.id, 'spaces/S/messages/M');
      });

      test('falls back to cloudEvent id when message name is absent', () {
        // Build a created event without a message name by encoding a fresh map
        final event = <String, dynamic>{
          'id': 'fallback-id',
          'type': 'google.workspace.chat.message.v1.created',
          'specversion': '1.0',
          'data': <String, dynamic>{
            'message': <String, dynamic>{
              // deliberately no 'name' field
              'sender': <String, dynamic>{'name': 'users/123', 'type': 'HUMAN'},
              'text': 'Hello',
              'space': <String, dynamic>{'name': 'spaces/S', 'type': 'SPACE'},
            },
          },
        };

        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(receivedMessageFrom(event));
        expect(result, isA<MessageResult>());
        expect((result as MessageResult).messages.first.id, 'fallback-id');
      });

      test('defaults spaceType to SPACE when absent from CloudEvent', () {
        final event = <String, dynamic>{
          'id': 'evt-1',
          'type': 'google.workspace.chat.message.v1.created',
          'specversion': '1.0',
          'data': <String, dynamic>{
            'message': <String, dynamic>{
              'name': 'spaces/S/messages/M',
              'sender': <String, dynamic>{'name': 'users/123', 'type': 'HUMAN'},
              'text': 'Hello',
              'space': <String, dynamic>{
                'name': 'spaces/S',
                // no 'type' key — Space Events CloudEvents may omit this
              },
            },
          },
        };

        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(receivedMessageFrom(event));
        expect(result, isA<MessageResult>());
        final metadata = (result as MessageResult).messages.first.metadata;
        expect(metadata['spaceType'], 'SPACE');
      });

      test('omits senderDisplayName from metadata when absent from CloudEvent', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(receivedMessageFrom(sampleCreatedEvent(senderDisplayName: null)));
        expect(result, isA<MessageResult>());
        final metadata = (result as MessageResult).messages.first.metadata;
        expect(metadata.containsKey('senderDisplayName'), isFalse);
      });

      test('captures spaceDisplayName in metadata when present', () {
        final event = sampleCreatedEvent();
        final data = Map<String, dynamic>.from(event['data'] as Map<String, dynamic>);
        final message = Map<String, dynamic>.from(data['message'] as Map<String, dynamic>);
        final space = Map<String, dynamic>.from(message['space'] as Map<String, dynamic>);
        space['displayName'] = 'Primary Space';
        message['space'] = space;
        data['message'] = message;
        event['data'] = data;

        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(receivedMessageFrom(event));

        expect(result, isA<MessageResult>());
        expect((result as MessageResult).messages.first.metadata['spaceDisplayName'], 'Primary Space');
      });
    });

    group('bot filtering', () {
      test('filters messages with sender type BOT', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(receivedMessageFrom(sampleCreatedEvent(senderType: 'BOT')));
        expect(result, isA<Filtered>());
        expect((result as Filtered).reason, contains('bot'));
      });

      test('filters messages matching configured botUser', () {
        final adapter = CloudEventAdapter(botUser: 'users/BOT_123');
        final result = adapter.processMessage(
          receivedMessageFrom(sampleCreatedEvent(senderName: 'users/BOT_123', senderType: 'HUMAN')),
        );
        expect(result, isA<Filtered>());
      });

      test('does not filter non-bot messages', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(receivedMessageFrom(sampleCreatedEvent(senderType: 'HUMAN')));
        expect(result, isA<MessageResult>());
      });

      test('does not filter when botUser is null', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(receivedMessageFrom(sampleCreatedEvent(senderType: 'HUMAN')));
        expect(result, isA<MessageResult>());
      });

      test('does not filter when sender name does not match botUser', () {
        final adapter = CloudEventAdapter(botUser: 'users/BOT_123');
        final result = adapter.processMessage(
          receivedMessageFrom(sampleCreatedEvent(senderName: 'users/HUMAN_456', senderType: 'HUMAN')),
        );
        expect(result, isA<MessageResult>());
      });
    });

    group('batchCreated', () {
      test('parses batch with multiple messages', () {
        final adapter = CloudEventAdapter();
        final batchEvent = sampleBatchCreatedEvent(
          messageResources: [
            sampleMessageResource(messageName: 'spaces/S/messages/M1', senderName: 'users/U1', text: 'First'),
            sampleMessageResource(messageName: 'spaces/S/messages/M2', senderName: 'users/U2', text: 'Second'),
            sampleMessageResource(messageName: 'spaces/S/messages/M3', senderName: 'users/U3', text: 'Third'),
          ],
        );

        final result = adapter.processMessage(receivedMessageFrom(batchEvent));
        expect(result, isA<MessageResult>());
        final messages = (result as MessageResult).messages;
        expect(messages, hasLength(3));
        expect(messages[0].text, 'First');
        expect(messages[1].text, 'Second');
        expect(messages[2].text, 'Third');
        expect(messages[0].senderJid, 'users/U1');
      });

      test('filters bot messages within batch', () {
        final adapter = CloudEventAdapter();
        final batchEvent = sampleBatchCreatedEvent(
          messageResources: [
            sampleMessageResource(senderName: 'users/U1', senderType: 'HUMAN', text: 'Human 1'),
            sampleMessageResource(senderName: 'users/BOT', senderType: 'BOT', text: 'Bot msg'),
            sampleMessageResource(senderName: 'users/U2', senderType: 'HUMAN', text: 'Human 2'),
          ],
        );

        final result = adapter.processMessage(receivedMessageFrom(batchEvent));
        expect(result, isA<MessageResult>());
        expect((result as MessageResult).messages, hasLength(2));
        expect(result.messages.map((m) => m.text).toList(), ['Human 1', 'Human 2']);
      });

      test('returns Filtered when all batch messages are bots', () {
        final adapter = CloudEventAdapter();
        final batchEvent = sampleBatchCreatedEvent(
          messageResources: [
            sampleMessageResource(senderType: 'BOT', text: 'Bot 1'),
            sampleMessageResource(senderType: 'BOT', text: 'Bot 2'),
          ],
        );

        final result = adapter.processMessage(receivedMessageFrom(batchEvent));
        expect(result, isA<Filtered>());
      });

      test('skips entries with missing message resource', () {
        final adapter = CloudEventAdapter();
        final batchEvent = {
          'id': 'evt-1',
          'type': 'google.workspace.chat.message.v1.batchCreated',
          'specversion': '1.0',
          'data': {
            'messages': [
              {'message': sampleMessageResource(text: 'Valid')},
              {'no_message_key': 'bad entry'},
              {'message': sampleMessageResource(text: 'Also valid')},
            ],
          },
        };

        final result = adapter.processMessage(receivedMessageFrom(batchEvent));
        expect(result, isA<MessageResult>());
        expect((result as MessageResult).messages, hasLength(2));
      });

      test('handles empty messages array', () {
        final adapter = CloudEventAdapter();
        final batchEvent = {
          'id': 'evt-1',
          'type': 'google.workspace.chat.message.v1.batchCreated',
          'specversion': '1.0',
          'data': {'messages': <dynamic>[]},
        };

        final result = adapter.processMessage(receivedMessageFrom(batchEvent));
        expect(result, isA<Acknowledged>());
      });

      test('handles missing messages field', () {
        final adapter = CloudEventAdapter();
        final batchEvent = {
          'id': 'evt-1',
          'type': 'google.workspace.chat.message.v1.batchCreated',
          'specversion': '1.0',
          'data': <String, dynamic>{},
        };

        final result = adapter.processMessage(receivedMessageFrom(batchEvent));
        expect(result, isA<Acknowledged>());
      });
    });

    group('log-only events', () {
      for (final eventType in [
        'google.workspace.chat.message.v1.updated',
        'google.workspace.chat.message.v1.deleted',
        'google.workspace.chat.message.v1.batchUpdated',
        'google.workspace.chat.message.v1.batchDeleted',
      ]) {
        test('returns LogOnly for $eventType', () {
          final adapter = CloudEventAdapter();
          final event = {'id': 'evt-1', 'type': eventType, 'specversion': '1.0', 'data': <String, dynamic>{}};
          final result = adapter.processMessage(receivedMessageFrom(event));
          expect(result, isA<LogOnly>());
          expect((result as LogOnly).eventType, eventType);
        });
      }

      test('returns LogOnly for unknown event type', () {
        final adapter = CloudEventAdapter();
        final event = {
          'id': 'evt-1',
          'type': 'google.workspace.chat.reaction.v1.created',
          'specversion': '1.0',
          'data': <String, dynamic>{},
        };
        final result = adapter.processMessage(receivedMessageFrom(event));
        expect(result, isA<LogOnly>());
        expect((result as LogOnly).eventType, 'google.workspace.chat.reaction.v1.created');
      });
    });

    group('malformed payloads', () {
      test('handles invalid base64 data', () {
        final adapter = CloudEventAdapter();
        final msg = const ReceivedMessage(
          ackId: 'ack-1',
          data: '!!!not-base64!!!',
          messageId: 'msg-1',
          publishTime: '2024-03-15T10:30:00Z',
          attributes: {},
        );
        final result = adapter.processMessage(msg);
        expect(result, isA<Acknowledged>());
      });

      test('handles non-JSON base64 data', () {
        final adapter = CloudEventAdapter();
        final msg = ReceivedMessage(
          ackId: 'ack-1',
          data: base64.encode(utf8.encode('not json at all')),
          messageId: 'msg-1',
          publishTime: '2024-03-15T10:30:00Z',
          attributes: const {},
        );
        final result = adapter.processMessage(msg);
        expect(result, isA<Acknowledged>());
      });

      test('handles JSON array instead of object', () {
        final adapter = CloudEventAdapter();
        final msg = ReceivedMessage(
          ackId: 'ack-1',
          data: base64.encode(utf8.encode('[1, 2, 3]')),
          messageId: 'msg-1',
          publishTime: '2024-03-15T10:30:00Z',
          attributes: const {},
        );
        final result = adapter.processMessage(msg);
        expect(result, isA<Acknowledged>());
        expect((result as Acknowledged).reason, contains('JSON object'));
      });

      test('handles missing type field', () {
        final adapter = CloudEventAdapter();
        final event = {'id': 'evt-1', 'specversion': '1.0', 'data': <String, dynamic>{}};
        final result = adapter.processMessage(receivedMessageFrom(event));
        expect(result, isA<Acknowledged>());
      });

      test('handles empty type field', () {
        final adapter = CloudEventAdapter();
        final event = {'id': 'evt-1', 'type': '', 'specversion': '1.0', 'data': <String, dynamic>{}};
        final result = adapter.processMessage(receivedMessageFrom(event));
        expect(result, isA<Acknowledged>());
      });

      test('handles created event with missing data.message', () {
        final adapter = CloudEventAdapter();
        final event = {
          'id': 'evt-1',
          'type': 'google.workspace.chat.message.v1.created',
          'specversion': '1.0',
          'data': <String, dynamic>{},
        };
        final result = adapter.processMessage(receivedMessageFrom(event));
        expect(result, isA<Acknowledged>());
      });

      test('handles created event with missing sender', () {
        final adapter = CloudEventAdapter();
        final event = <String, dynamic>{
          'id': 'evt-1',
          'type': 'google.workspace.chat.message.v1.created',
          'specversion': '1.0',
          'data': <String, dynamic>{
            'message': <String, dynamic>{
              'name': 'spaces/S/messages/M',
              'text': 'Hello',
              'space': <String, dynamic>{'name': 'spaces/S', 'type': 'SPACE'},
            },
          },
        };
        final result = adapter.processMessage(receivedMessageFrom(event));
        expect(result, isA<Acknowledged>());
      });

      test('handles created event with missing space', () {
        final adapter = CloudEventAdapter();
        final event = <String, dynamic>{
          'id': 'evt-1',
          'type': 'google.workspace.chat.message.v1.created',
          'specversion': '1.0',
          'data': <String, dynamic>{
            'message': <String, dynamic>{
              'name': 'spaces/S/messages/M',
              'text': 'Hello',
              'sender': <String, dynamic>{'name': 'users/U123', 'displayName': 'Test User', 'type': 'HUMAN'},
            },
          },
        };
        final result = adapter.processMessage(receivedMessageFrom(event));
        expect(result, isA<Acknowledged>());
      });

      test('handles created event with empty text and no argumentText', () {
        final adapter = CloudEventAdapter();
        final result = adapter.processMessage(receivedMessageFrom(sampleCreatedEvent(text: '')));
        // Empty text returns null from _parseMessageResource → Acknowledged
        expect(result, isNot(isA<MessageResult>()));
      });

      test('handles empty ReceivedMessage data', () {
        final adapter = CloudEventAdapter();
        final msg = const ReceivedMessage(
          ackId: 'ack-1',
          data: '',
          messageId: 'msg-1',
          publishTime: '2024-03-15T10:30:00Z',
          attributes: {},
        );
        final result = adapter.processMessage(msg);
        expect(result, isA<Acknowledged>());
      });

      test('never throws — always returns AdapterResult', () {
        final adapter = CloudEventAdapter();
        final variants = [
          const ReceivedMessage(ackId: 'a', data: '!!!', messageId: 'x', publishTime: '', attributes: {}),
          ReceivedMessage(
            ackId: 'a',
            data: base64.encode(utf8.encode('not json')),
            messageId: 'x',
            publishTime: '',
            attributes: const {},
          ),
          receivedMessageFrom({'no_type': 'here'}),
          receivedMessageFrom({'type': 'google.workspace.chat.message.v1.created', 'data': <String, dynamic>{}}),
        ];

        for (final msg in variants) {
          expect(() => adapter.processMessage(msg), returnsNormally, reason: 'processMessage should never throw');
          expect(adapter.processMessage(msg), isA<AdapterResult>());
        }
      });
    });
  });
}

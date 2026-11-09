import 'dart:async';

import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:test/test.dart';

import 'support/slack_harness.dart';

const _host = 'https://files.slack.com/files-pri/T1';

/// A file entry as Slack lists it on a `message` event.
Map<String, dynamic> _fileEntry(String id, String name, {String mimetype = 'text/plain', int size = 10, String? url}) =>
    {
      'id': id,
      'name': name,
      'mimetype': mimetype,
      'size': size,
      'url_private': url ?? '$_host-$id/$name',
      'url_private_download': url ?? '$_host-$id/download/$name',
    };

String _downloadUrl(String id, String name) => '$_host-$id/download/$name';

void main() {
  late SlackHarness harness;

  Future<void> start({SlackConfig? config}) async => harness = await SlackHarness.start(config: config);

  tearDown(() => harness.close());

  FakeSlackFileHost host() => harness.api.fileHost;

  void serve(String id, String name, List<int> bytes, {String contentType = 'application/octet-stream'}) {
    host().files[_downloadUrl(id, name)] = FakeSlackFile(
      bytes: bytes,
      contentType: contentType,
      sendsContentLength: true,
    );
  }

  Future<void> deliverFiles({
    String text = 'see attached',
    required List<Map<String, dynamic>> files,
    String channel = 'D1',
    String ts = '100.000100',
    bool mention = false,
  }) => harness.deliver([
    message(channel: channel, user: 'U1', text: text, ts: ts, files: files, subtype: 'file_share', mention: mention),
  ]);

  String filesReply() => harness.api.posts.singleWhere((post) => post.text.contains("couldn't use")).text;

  group('files reach the turn (OC04)', () {
    test('a PNG and a text file are downloaded with the bot token and ride the admitted message', () async {
      await start();
      final png = List<int>.generate(1024 * 1024, (i) => i % 251);
      serve('F1', 'shot.png', png, contentType: 'image/png');
      serve('F2', 'notes.md', 'hello notes'.codeUnits, contentType: 'text/markdown');

      await deliverFiles(
        files: [
          _fileEntry('F1', 'shot.png', mimetype: 'image/png', size: png.length),
          _fileEntry('F2', 'notes.md', mimetype: 'text/markdown'),
        ],
      );
      await harness.until(() => harness.turns.isNotEmpty);

      final turn = harness.turns.single.message;
      expect(turn.text, 'see attached');
      expect(
        [for (final file in turn.attachments) (file.filename, file.mediaType)],
        [('shot.png', 'image/png'), ('notes.md', 'text/markdown')],
      );
      expect(turn.attachments.first.bytes, png);
      expect(String.fromCharCodes(turn.attachments.last.bytes), 'hello notes');
      expect(host().requests.map((request) => request.headers['authorization']), everyElement('Bearer xoxb-fake'));
      expect(harness.api.posts, isEmpty, reason: 'nothing was refused, so nothing is posted');
    });

    test('a message without files takes the unchanged path and carries no attachments', () async {
      await start();

      await harness.deliver([message(channel: 'D1', user: 'U1', text: 'plain', ts: '100.1')]);

      expect(harness.turns.single.message.attachments, isEmpty);
      expect(host().requests, isEmpty);
    });
  });

  group('size and count bounds', () {
    test(
      'an oversize and a sixth file are never fetched, an overrunning body is abandoned, the rest are kept',
      () async {
        await start();
        for (final name in ['a', 'd', 'e']) {
          serve('F$name', '$name.txt', [1, 2, 3]);
        }
        final overrun = List.filled(21 * 1024 * 1024, 7);
        host().files[_downloadUrl('Fb', 'big.bin')] = FakeSlackFile(bytes: overrun);
        host().files[_downloadUrl('Fx', 'sixth.txt')] = FakeSlackFile(bytes: [1]);

        await deliverFiles(
          files: [
            _fileEntry('Fa', 'a.txt'),
            _fileEntry('Fh', 'huge.bin', size: 25 * 1024 * 1024),
            _fileEntry('Fb', 'big.bin', size: 1024 * 1024),
            _fileEntry('Fd', 'd.txt'),
            _fileEntry('Fe', 'e.txt'),
            _fileEntry('Fx', 'sixth.txt'),
          ],
        );
        await harness.until(() => harness.turns.isNotEmpty);

        final turn = harness.turns.single.message;
        expect(turn.attachments.map((file) => file.filename), ['a.txt', 'd.txt', 'e.txt']);
        expect(turn.text, 'see attached', reason: 'the text is still processed');
        final requested = host().requests.map((request) => request.url.toString());
        expect(
          requested,
          isNot(contains(_downloadUrl('Fh', 'huge.bin'))),
          reason: 'declared over 20 MB: never fetched',
        );
        expect(requested, isNot(contains(_downloadUrl('Fx', 'sixth.txt'))), reason: 'past 5 files: never fetched');
        expect(host().bytesServed, lessThan(overrun.length), reason: 'the overrunning download was aborted');
        final reply = filesReply();
        expect(harness.api.posts.where((post) => post.text.contains("couldn't use")), hasLength(1));
        expect(reply, contains('`huge.bin`: larger than the 20 MB limit'));
        expect(reply, contains('`big.bin`: larger than the 20 MB limit'));
        expect(reply, contains('`sixth.txt`: over the limit of 5 files per message'));
        expect(harness.api.posts.single.threadTs, '100.000100');
      },
    );
  });

  group('failures are named, not attached (S12)', () {
    test('403, a dropped connection and a sign-in page each name the file and the failure', () async {
      await start();
      host().files[_downloadUrl('F1', 'denied.png')] = FakeSlackFile(status: 403);
      host().files[_downloadUrl('F2', 'dropped.png')] = FakeSlackFile(dropsConnection: true);
      host().files[_downloadUrl('F3', 'page.png')] = FakeSlackFile(
        bytes: '<html>sign in</html>'.codeUnits,
        contentType: 'text/html',
      );
      serve('F4', 'fine.txt', [1]);

      await deliverFiles(
        files: [
          _fileEntry('F1', 'denied.png', mimetype: 'image/png'),
          _fileEntry('F2', 'dropped.png', mimetype: 'image/png'),
          _fileEntry('F3', 'page.png', mimetype: 'image/png'),
          _fileEntry('F4', 'fine.txt'),
        ],
      );
      await harness.until(() => harness.turns.isNotEmpty);

      final turn = harness.turns.single.message;
      expect(turn.attachments.map((file) => file.filename), ['fine.txt']);
      expect(turn.text, 'see attached');
      final reply = filesReply();
      expect(reply, contains('`denied.png`: Slack refused the download (HTTP 403)'));
      expect(reply, contains('`dropped.png`: the download failed'));
      expect(reply, contains('`page.png`: Slack answered with a web page'));
      expect(reply, contains('files:read'));
      expect(reply, isNot(contains('xoxb')));
      expect(reply, isNot(contains('https://')));
    });

    test('a file name cannot ping through the reply', () async {
      await start();
      host().files[_downloadUrl('F1', 'x.png')] = FakeSlackFile(status: 500);

      await deliverFiles(
        files: [
          {..._fileEntry('F1', 'x.png'), 'name': '<!channel> <@U9>\nline.png'},
        ],
      );
      await harness.until(() => harness.api.posts.isNotEmpty);

      final reply = filesReply();
      expect(reply, isNot(contains('<!channel>')));
      expect(reply, isNot(contains('<@U9>')));
      expect(reply, contains('&lt;!channel&gt;'));
    });
  });

  group('files Slack will not hand over (S13)', () {
    test('a Slack Connect stub and an externally hosted file are refused with their reasons', () async {
      await start();

      await deliverFiles(
        files: [
          {'id': 'F9', 'file_access': 'check_file_info'},
          {'id': 'F8', 'name': 'plan.gdoc', 'is_external': true, 'external_type': 'gdrive', 'mode': 'external'},
        ],
      );
      await harness.until(() => harness.turns.isNotEmpty);

      expect(host().requests, isEmpty, reason: 'there is nothing to download, and files.info is never asked');
      final reply = filesReply();
      expect(reply, contains('`F9`: shared from another Slack workspace'));
      expect(reply, contains('`plan.gdoc`: hosted outside Slack'));
      expect(harness.turns.single.message.text, 'see attached');
      expect(harness.turns.single.message.attachments, isEmpty);
    });
  });

  group('one turn per message with files (S14)', () {
    test('a file-only message starts one turn that carries the file', () async {
      await start();
      serve('F1', 'only.txt', [1, 2]);

      await deliverFiles(text: '', files: [_fileEntry('F1', 'only.txt')]);
      await harness.until(() => harness.turns.isNotEmpty);

      expect(harness.turns, hasLength(1));
      expect(harness.turns.single.message.text, isEmpty);
      expect(harness.turns.single.message.attachments.single.filename, 'only.txt');
    });

    test('a message whose files all failed and that has no text starts no turn, and says why', () async {
      await start();

      await deliverFiles(text: '', files: [_fileEntry('F1', 'gone.txt')]);
      await harness.until(() => harness.api.posts.isNotEmpty);

      expect(harness.turns, isEmpty);
      expect(filesReply(), contains('`gone.txt`'));
    });

    test('a mention with a file, delivered as app_mention and message, starts one turn naming the file once', () async {
      await start();
      serve('F1', 'trace.log', [1, 2, 3]);
      final withFile = message(
        channel: 'C1',
        user: 'U1',
        text: 'look at this',
        ts: '200.1',
        mention: true,
        files: [_fileEntry('F1', 'trace.log')],
        subtype: 'file_share',
      );
      final mentionEvent = {...withFile, 'type': 'app_mention'}..remove('files');

      await harness.deliver([mentionEvent, withFile]);
      await harness.until(() => harness.turns.isNotEmpty);

      expect(harness.turns, hasLength(1));
      expect(harness.turns.single.message.attachments.map((file) => file.filename), ['trace.log']);
      expect(host().requests, hasLength(1));
    });
  });

  group('a message the gate refuses fetches nothing (S16)', () {
    test('a sender dm_access refuses, an unlisted channel and an unmentioned channel message', () async {
      await start();
      serve('F1', 'x.txt', [1]);
      final file = _fileEntry('F1', 'x.txt');

      await harness.deliver([
        message(channel: 'D9', user: 'U9', text: 'hi', ts: '300.1', files: [file], subtype: 'file_share'),
        message(
          channel: 'C9',
          user: 'U1',
          text: 'hi',
          ts: '300.2',
          files: [file],
          subtype: 'file_share',
          mention: true,
        ),
        message(channel: 'C1', user: 'U1', text: 'hi', ts: '300.3', files: [file], subtype: 'file_share'),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(host().requests, isEmpty);
      expect(harness.turns, isEmpty);
      expect(harness.api.posts, isEmpty);
    });
  });

  group('a slow download delays nothing else (S17)', () {
    test('the envelope is acknowledged and a later one is handled while the file is still downloading', () async {
      await start();
      final gate = Completer<void>();
      host().files[_downloadUrl('F1', 'slow.txt')] = FakeSlackFile(bytes: [1], gate: gate);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });

      harness.server.sendEvent(
        eventCallback(
          message(
            channel: 'D1',
            user: 'U1',
            text: 'with file',
            ts: '400.1',
            files: [_fileEntry('F1', 'slow.txt')],
            subtype: 'file_share',
          ),
        ),
      );
      await harness.until(() => host().requests.isNotEmpty);
      await harness.deliver([message(channel: 'D1', user: 'U1', text: 'next', ts: '400.2', threadTs: '400.0')]);

      expect(harness.server.acknowledgements, hasLength(greaterThanOrEqualTo(2)));
      expect(harness.turns.map((turn) => turn.message.text), ['next'], reason: 'handled while the download is open');

      gate.complete();
      await harness.until(() => harness.turns.length == 2);
      expect(harness.turns.last.message.attachments.single.filename, 'slow.txt');
    });

    test('the dispatch returns while the download is open, so the Events API path never waits either', () async {
      await start();
      final gate = Completer<void>();
      host().files[_downloadUrl('F1', 'slow.txt')] = FakeSlackFile(bytes: [1], gate: gate);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });

      await harness.channel.dispatch
          .dispatch(
            SlackEnvelope(
              kind: SlackEnvelopeKind.event,
              payload: eventCallback(
                message(
                  channel: 'D1',
                  user: 'U1',
                  text: 'with file',
                  ts: '500.1',
                  files: [_fileEntry('F1', 'slow.txt')],
                  subtype: 'file_share',
                ),
              ),
            ),
          )
          .timeout(const Duration(seconds: 2));

      expect(harness.turns, isEmpty, reason: 'the turn waits for its file, the dispatch does not');
    });
  });

  group('the token never leaves', () {
    test('no reply or log line carries the bot token', () async {
      await start();
      host().files[_downloadUrl('F1', 'a.png')] = FakeSlackFile(status: 403);

      await deliverFiles(files: [_fileEntry('F1', 'a.png')]);
      await harness.until(() => harness.api.posts.isNotEmpty);

      for (final post in harness.api.posts) {
        expect(post.text, isNot(contains('xoxb')));
      }
      for (final record in harness.logs) {
        expect('${record.message} ${record.error}', isNot(contains('xoxb')));
      }
    });
  });
}

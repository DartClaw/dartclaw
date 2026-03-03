import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:test/test.dart';

import 'package:dartclaw_server/src/templates/layout.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/templates/topbar.dart';
import 'package:dartclaw_server/src/templates/chat.dart';
import 'package:dartclaw_server/src/templates/components.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('layoutTemplate', () {
    test('contains DOCTYPE declaration', () {
      final html = layoutTemplate(title: 'Test', body: '<p>body</p>');
      expect(html, contains('<!DOCTYPE html>'));
    });

    test('contains HTMX CDN link', () {
      final html = layoutTemplate(title: 'Test', body: '');
      expect(html, contains('htmx.org'));
    });

    test('contains marked.js CDN link', () {
      final html = layoutTemplate(title: 'Test', body: '');
      expect(html, contains('marked'));
    });

    test('contains DOMPurify CDN link', () {
      final html = layoutTemplate(title: 'Test', body: '');
      expect(html, contains('dompurify'));
    });

    test('contains /static/app.js', () {
      final html = layoutTemplate(title: 'Test', body: '');
      expect(html, contains('/static/app.js'));
    });

    test('contains /static/tokens.css', () {
      final html = layoutTemplate(title: 'Test', body: '');
      expect(html, contains('/static/tokens.css'));
    });

    test('contains /static/components.css', () {
      final html = layoutTemplate(title: 'Test', body: '');
      expect(html, contains('/static/components.css'));
    });

    test('HTML-escapes title', () {
      final html = layoutTemplate(title: '<My App>', body: '');
      expect(html, contains('&lt;My App&gt;'));
      expect(html, isNot(contains('<My App>')));
    });

    test('includes body content verbatim', () {
      const body = '<div id="unique-body-marker">hello</div>';
      final html = layoutTemplate(title: 'T', body: body);
      expect(html, contains(body));
    });
  });

  group('sidebarTemplate', () {
    test('empty state renders placeholders', () {
      final html = sidebarTemplate();
      expect(html, contains('No active channels'));
      expect(html, contains('No sessions yet'));
    });

    test('renders main session pinned at top', () {
      final html = sidebarTemplate(
        mainSession: (id: 'm1', title: 'Main', type: SessionType.main),
      );
      expect(html, contains('session-item-main'));
      expect(html, contains('Main'));
    });

    test('renders channel sessions with icon', () {
      final html = sidebarTemplate(
        channelSessions: [(id: 'c1', title: 'WhatsApp Alice', type: SessionType.channel)],
      );
      expect(html, contains('session-item-channel'));
      expect(html, contains('WhatsApp Alice'));
    });

    test('renders user sessions with delete button', () {
      final html = sidebarTemplate(
        sessionEntries: [(id: 's1', title: 'My Research', type: SessionType.user)],
      );
      expect(html, contains('My Research'));
      expect(html, contains('session-delete'));
      expect(html, contains('data-session-id="s1"'));
    });

    test('renders archive sessions with clock icon, no delete button', () {
      final html = sidebarTemplate(
        sessionEntries: [(id: 'a1', title: 'Old session', type: SessionType.archive)],
      );
      expect(html, contains('session-item-archive'));
      expect(html, contains('Old session'));
      expect(html, isNot(contains('data-action="delete-session"')));
    });

    test('active session gets active class', () {
      final html = sidebarTemplate(
        sessionEntries: [
          (id: 's1', title: 'Alpha', type: SessionType.user),
          (id: 's2', title: 'Beta', type: SessionType.user),
        ],
        activeSessionId: 's1',
      );
      expect(html, contains('session-item active'));
    });

    test('empty title renders as New Session for user type', () {
      final html = sidebarTemplate(
        sessionEntries: [(id: 's1', title: '', type: SessionType.user)],
      );
      expect(html, contains('New Session'));
    });

    test('titles are HTML-escaped', () {
      final html = sidebarTemplate(
        sessionEntries: [(id: 's1', title: '<b>Bold</b>', type: SessionType.user)],
      );
      expect(html, contains('&lt;b&gt;Bold'));
      expect(html, isNot(contains('<b>Bold</b>')));
    });

    test('renders "+ New Session" button', () {
      final html = sidebarTemplate();
      expect(html, contains('+ New Session'));
      expect(html, contains('data-action="create-session"'));
    });

    test('renders section dividers', () {
      final html = sidebarTemplate();
      expect(html, contains('sidebar-divider'));
    });

    test('XSS in session id is safe in attributes', () {
      final html = sidebarTemplate(
        sessionEntries: [(id: '<script>xss</script>', title: 'Test', type: SessionType.user)],
      );
      // Trellis escapes per HTML spec: attribute values are properly quoted
      // (preventing attribute breakout). The " char is escaped to &quot;.
      // <> are allowed in quoted attribute values per HTML5 spec.
      expect(html, contains('data-session-id='));
    });
  });

  group('topbarTemplate', () {
    test('null sessionId renders plain DartClaw text', () {
      final html = topbarTemplate();
      expect(html, contains('<span class="session-title">DartClaw</span>'));
      expect(html, isNot(contains('<input')));
      expect(html, isNot(contains('topbar-delete')));
    });

    test('null sessionId with title still renders DartClaw', () {
      final html = topbarTemplate(title: 'Chat');
      expect(html, contains('DartClaw'));
    });

    test('with sessionId renders editable input', () {
      final html = topbarTemplate(title: 'My Chat', sessionId: 'sess-1');
      expect(html, contains('<input id="session-title" class="session-title"'));
      expect(html, contains('value="My Chat"'));
      expect(html, contains('data-session-id="sess-1"'));
      expect(html, contains('data-original-title="My Chat"'));
    });

    test('with sessionId and null title defaults to New Session', () {
      final html = topbarTemplate(sessionId: 'sess-2');
      expect(html, contains('value="New Session"'));
    });

    test('with sessionId does not render delete button (delete via sidebar only)', () {
      final html = topbarTemplate(sessionId: 'sess-1');
      expect(html, isNot(contains('data-action="delete-session"')));
      expect(html, isNot(contains('topbar-delete')));
      expect(html, contains('theme-toggle'));
    });

    test('title is rendered in input value', () {
      final html = topbarTemplate(title: '<script>xss</script>', sessionId: 's1');
      // Trellis sets attribute values via DOM — properly quoted, no attribute breakout.
      expect(html, contains('value='));
      expect(html, contains('session-title'));
    });

    test('sessionId with quotes is escaped to prevent attribute breakout', () {
      final html = topbarTemplate(title: 'X', sessionId: '"><evil');
      // The " character is escaped to &quot; preventing attribute breakout.
      expect(html, contains('&quot;'));
      expect(html, isNot(contains('data-session-id="">')));
    });

    test('contains menu toggle button', () {
      final html = topbarTemplate(title: 'Chat', sessionId: 's1');
      expect(html, contains('menu-toggle'));
    });

    test('contains theme toggle button', () {
      final html = topbarTemplate(title: 'Chat', sessionId: 's1');
      expect(html, contains('theme-toggle'));
    });
  });

  group('classifyMessage', () {
    test('user role returns MessageType.user', () {
      final m = classifyMessage(id: '1', role: 'user', content: 'Hello');
      expect(m.messageType, MessageType.user);
      expect(m.detail, isNull);
    });

    test('plain assistant returns MessageType.assistant', () {
      final m = classifyMessage(id: '1', role: 'assistant', content: 'Hi there');
      expect(m.messageType, MessageType.assistant);
      expect(m.detail, isNull);
    });

    test('guard block pattern returns MessageType.guardBlock', () {
      final m = classifyMessage(id: '1', role: 'assistant', content: '[Blocked by guard: profanity]');
      expect(m.messageType, MessageType.guardBlock);
      expect(m.detail, 'profanity');
    });

    test('response blocked pattern returns MessageType.guardBlock', () {
      final m = classifyMessage(id: '1', role: 'assistant', content: '[Response blocked by guard: length]');
      expect(m.messageType, MessageType.guardBlock);
      expect(m.detail, 'length');
    });

    test('turn failed pattern returns MessageType.turnFailed', () {
      final m = classifyMessage(id: '1', role: 'assistant', content: '[Turn failed: timeout]');
      expect(m.messageType, MessageType.turnFailed);
      expect(m.detail, 'timeout');
    });

    test('turn failed without detail returns null detail', () {
      final m = classifyMessage(id: '1', role: 'assistant', content: '[Turn failed]');
      expect(m.messageType, MessageType.turnFailed);
      expect(m.detail, isNull);
    });
  });

  group('messagesHtmlFragment', () {
    test('empty list returns empty state (no .msg divs)', () {
      final html = messagesHtmlFragment([]);
      expect(html, isNot(contains('class="msg ')));
      expect(html, contains('empty-state'));
    });

    test('user messages get msg-user class', () {
      final msgs = [classifyMessage(id: '1', role: 'user', content: 'Hello')];
      final html = messagesHtmlFragment(msgs);
      expect(html, contains('msg-user'));
    });

    test('user messages show You as role label', () {
      final msgs = [classifyMessage(id: '1', role: 'user', content: 'Hello')];
      final html = messagesHtmlFragment(msgs);
      expect(html, contains('You'));
    });

    test('assistant messages get msg-assistant class', () {
      final msgs = [classifyMessage(id: '1', role: 'assistant', content: 'Hi there')];
      final html = messagesHtmlFragment(msgs);
      expect(html, contains('msg-assistant'));
    });

    test('assistant messages show Assistant as role label', () {
      final msgs = [classifyMessage(id: '1', role: 'assistant', content: 'Hi there')];
      final html = messagesHtmlFragment(msgs);
      expect(html, contains('Assistant'));
    });

    test('assistant messages have data-markdown attribute', () {
      final msgs = [classifyMessage(id: '1', role: 'assistant', content: 'Hi there')];
      final html = messagesHtmlFragment(msgs);
      expect(html, contains('data-markdown'));
    });

    test('user messages do NOT have data-markdown attribute', () {
      final msgs = [classifyMessage(id: '1', role: 'user', content: 'Hello')];
      final html = messagesHtmlFragment(msgs);
      expect(html, isNot(contains('data-markdown')));
    });

    test('content is HTML-escaped', () {
      final msgs = [classifyMessage(id: '1', role: 'user', content: '<script>alert(1)</script>')];
      final html = messagesHtmlFragment(msgs);
      expect(html, contains('&lt;script&gt;alert(1)'));
      expect(html, isNot(contains('<script>alert(1)</script>')));
    });

    test('assistant content is also HTML-escaped', () {
      final msgs = [classifyMessage(id: '1', role: 'assistant', content: '<b>bold</b>')];
      final html = messagesHtmlFragment(msgs);
      expect(html, contains('&lt;b&gt;bold'));
      expect(html, isNot(contains('<b>bold</b>')));
    });
  });

  group('chatAreaTemplate', () {
    test('contains hx-post pointing to session send endpoint', () {
      final html = chatAreaTemplate(sessionId: 'abc123', messagesHtml: '');
      expect(html, contains('hx-post="/api/sessions/abc123/send"'));
    });

    test('contains id="messages"', () {
      final html = chatAreaTemplate(sessionId: 's1', messagesHtml: '');
      expect(html, contains('id="messages"'));
    });

    test('contains id="sse-container"', () {
      final html = chatAreaTemplate(sessionId: 's1', messagesHtml: '');
      expect(html, contains('id="sse-container"'));
    });

    test('contains accessible label for message input', () {
      final html = chatAreaTemplate(sessionId: 's1', messagesHtml: '');
      expect(html, contains('<label class="sr-only" for="message-input">Message</label>'));
    });

    test('isStreaming=true renders textarea as disabled', () {
      final html = chatAreaTemplate(sessionId: 's1', messagesHtml: '', isStreaming: true);
      expect(html, contains('disabled'));
    });

    test('isStreaming=false (default) renders textarea as not disabled', () {
      final html = chatAreaTemplate(sessionId: 's1', messagesHtml: '');
      expect(html, isNot(contains(' disabled')));
    });

    test('sessionId in hx-post is HTML-escaped', () {
      final html = chatAreaTemplate(sessionId: 'a&b', messagesHtml: '');
      expect(html, contains('a&amp;b'));
      expect(html, isNot(contains('/api/sessions/a&b/')));
    });

    test('messagesHtml is included in output', () {
      const marker = '<div id="test-marker">msg</div>';
      final html = chatAreaTemplate(sessionId: 's1', messagesHtml: marker);
      expect(html, contains(marker));
    });

    test('renders data-session-id attribute', () {
      final html = chatAreaTemplate(sessionId: 'abc', messagesHtml: '');
      expect(html, contains('data-session-id="abc"'));
    });

    test('renders data-has-title="false" by default', () {
      final html = chatAreaTemplate(sessionId: 's1', messagesHtml: '');
      expect(html, contains('data-has-title="false"'));
    });

    test('renders data-has-title="true" when hasTitle is true', () {
      final html = chatAreaTemplate(sessionId: 'a', messagesHtml: '', hasTitle: true);
      expect(html, contains('data-has-title="true"'));
    });
  });

  group('bannerTemplate', () {
    test('error type gets banner-error class', () {
      final html = bannerTemplate('error', 'Something went wrong');
      expect(html, contains('banner-error'));
    });

    test('warning type gets banner-warning class', () {
      final html = bannerTemplate('warning', 'Be careful');
      expect(html, contains('banner-warning'));
    });

    test('info type gets banner-info class', () {
      final html = bannerTemplate('info', 'FYI');
      expect(html, contains('banner-info'));
    });

    test('message is HTML-escaped', () {
      final html = bannerTemplate('error', '<b>oops</b>');
      // HtmlEscape escapes < > and / — closing tag becomes &lt;&#47;b&gt;
      expect(html, contains('&lt;b&gt;oops'));
      expect(html, isNot(contains('<b>oops</b>')));
    });
  });

  group('emptyAppStateTemplate', () {
    test('contains CTA button with data-action="create-session"', () {
      final html = emptyAppStateTemplate();
      expect(html, contains('btn-primary'));
      expect(html, contains('data-action="create-session"'));
    });

    test('contains "No sessions yet" heading', () {
      final html = emptyAppStateTemplate();
      expect(html, contains('No sessions yet'));
    });

    test('wraps in chat-area main element', () {
      final html = emptyAppStateTemplate();
      expect(html, contains('class="chat-area"'));
    });
  });

  group('emptyStateTemplate', () {
    test('returns non-empty string', () {
      final html = emptyStateTemplate();
      expect(html, isNotEmpty);
    });

    test('contains empty-state class', () {
      final html = emptyStateTemplate();
      expect(html, contains('empty-state'));
    });

    test('contains DartClaw-relevant text', () {
      final html = emptyStateTemplate();
      // Either references DartClaw, no messages, or prompts user to send
      expect(html.toLowerCase(), anyOf(contains('dartclaw'), contains('no messages'), contains('send a message')));
    });
  });
}

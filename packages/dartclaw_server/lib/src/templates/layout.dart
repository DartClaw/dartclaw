import 'helpers.dart';

/// Full HTML document wrapper. [title] is HTML-escaped; [body] is raw HTML.
String layoutTemplate({required String title, required String body}) => '''
<!DOCTYPE html>
<html lang="en" data-theme="">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${htmlEscape(title)} - DartClaw</title>
  <script>(function(){var t=localStorage.getItem('dartclaw-theme');if(t==='light')document.documentElement.dataset.theme='light';})();</script>
  <link
    href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&display=swap"
    rel="stylesheet">
  <link rel="stylesheet" href="/static/tokens.css">
  <link rel="stylesheet" href="/static/components.css">
  <link rel="stylesheet" href="/static/hljs-catppuccin-mocha.css" id="hljs-theme">
  <script defer src="https://unpkg.com/htmx.org@2.0.4/dist/htmx.min.js"
    integrity="sha384-HGfztofotfshcF7+8n44JQL2oJmowVChPTg48S+jvZoztPfvwD79OC/LTtG6dMp+"
    crossorigin="anonymous"></script>
  <script defer src="https://cdn.jsdelivr.net/npm/marked@15/marked.min.js"
    integrity="sha384-948ahk4ZmxYVYOc+rxN1H2gM1EJ2Duhp7uHtZ4WSLkV4Vtx5MUqnV+l7u9B+jFv+"
    crossorigin="anonymous"></script>
  <script defer src="/static/hljs.min.js"></script>
  <script defer src="https://cdn.jsdelivr.net/npm/dompurify@3/dist/purify.min.js"
    integrity="sha384-80VlBZnyAwkkqtSfg5NhPyZff6nU4K/qniLBL8Jnm4KDv6jZhLiYtJbhglg/i9ww"
    crossorigin="anonymous"></script>
</head>
<body>
$body
<div id="sidebar-backdrop" class="sidebar-backdrop"></div>
<script defer src="/static/app.js"></script>
</body>
</html>
''';

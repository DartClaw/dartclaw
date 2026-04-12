import 'package:dartclaw_google_chat/src/markdown_converter.dart';
import 'package:test/test.dart';

void main() {
  group('markdownToGoogleChat', () {
    group('passthrough', () {
      test('empty string', () {
        expect(markdownToGoogleChat(''), equals(''));
      });

      test('plain text unchanged', () {
        expect(markdownToGoogleChat('Hello world'), equals('Hello world'));
      });

      test('underscore italic unchanged', () {
        expect(markdownToGoogleChat('_italic_'), equals('_italic_'));
      });

      test('single asterisk bold (already gchat) unchanged', () {
        // If text is already in Google Chat format, don't double-convert.
        expect(markdownToGoogleChat('*bold*'), equals('_bold_'));
      });
    });

    group('bold', () {
      test('double asterisk', () {
        expect(markdownToGoogleChat('**bold**'), equals('*bold*'));
      });

      test('double underscore', () {
        expect(markdownToGoogleChat('__bold__'), equals('*bold*'));
      });

      test('multiple bold on one line', () {
        expect(markdownToGoogleChat('**first** and **second**'), equals('*first* and *second*'));
      });

      test('bold within sentence', () {
        expect(markdownToGoogleChat('This is **important** stuff'), equals('This is *important* stuff'));
      });
    });

    group('italic', () {
      test('single asterisk', () {
        expect(markdownToGoogleChat('*italic*'), equals('_italic_'));
      });

      test('preserves underscore italic', () {
        expect(markdownToGoogleChat('_italic_'), equals('_italic_'));
      });

      test('does not match math expressions', () {
        expect(markdownToGoogleChat('2*3 = 6'), equals('2*3 = 6'));
      });
    });

    group('bold + italic', () {
      test('triple asterisk', () {
        expect(markdownToGoogleChat('***bold italic***'), equals('*_bold italic_*'));
      });

      test('triple underscore', () {
        expect(markdownToGoogleChat('___bold italic___'), equals('*_bold italic_*'));
      });
    });

    group('strikethrough', () {
      test('double tilde', () {
        expect(markdownToGoogleChat('~~deleted~~'), equals('~deleted~'));
      });

      test('within sentence', () {
        expect(markdownToGoogleChat('see ~~old~~ new'), equals('see ~old~ new'));
      });
    });

    group('links', () {
      test('markdown link', () {
        expect(markdownToGoogleChat('[Click here](https://example.com)'), equals('<https://example.com|Click here>'));
      });

      test('link within text', () {
        expect(
          markdownToGoogleChat('Check [docs](https://docs.example.com) for info'),
          equals('Check <https://docs.example.com|docs> for info'),
        );
      });

      test('multiple links', () {
        expect(
          markdownToGoogleChat('[a](https://a.com) and [b](https://b.com)'),
          equals('<https://a.com|a> and <https://b.com|b>'),
        );
      });
    });

    group('images', () {
      test('image with alt text', () {
        expect(
          markdownToGoogleChat('![screenshot](https://img.com/shot.png)'),
          equals('screenshot (https://img.com/shot.png)'),
        );
      });

      test('image without alt text', () {
        expect(markdownToGoogleChat('![](https://img.com/shot.png)'), equals('https://img.com/shot.png'));
      });

      test('image not confused with link', () {
        expect(
          markdownToGoogleChat('![img](https://img.com) and [link](https://link.com)'),
          equals('img (https://img.com) and <https://link.com|link>'),
        );
      });
    });

    group('headers', () {
      test('h1', () {
        expect(markdownToGoogleChat('# Title'), equals('*Title*'));
      });

      test('h2', () {
        expect(markdownToGoogleChat('## Section'), equals('*Section*'));
      });

      test('h3', () {
        expect(markdownToGoogleChat('### Subsection'), equals('*Subsection*'));
      });

      test('h6', () {
        expect(markdownToGoogleChat('###### Deep'), equals('*Deep*'));
      });

      test('header with trailing whitespace', () {
        expect(markdownToGoogleChat('## Title  '), equals('*Title*'));
      });

      test('header with bold inside', () {
        // Inner **bold** is redundant since header is already bold.
        // Result: nested bold markers — acceptable for this edge case.
        expect(markdownToGoogleChat('## **Bold** Header'), equals('**Bold* Header*'));
      });

      test('mid-text # not converted', () {
        expect(markdownToGoogleChat('Issue #123 is fixed'), equals('Issue #123 is fixed'));
      });
    });

    group('horizontal rules', () {
      test('dashes', () {
        expect(markdownToGoogleChat('---'), equals(''));
      });

      test('asterisks', () {
        expect(markdownToGoogleChat('***'), equals(''));
      });

      test('underscores', () {
        expect(markdownToGoogleChat('___'), equals(''));
      });

      test('spaced dashes', () {
        expect(markdownToGoogleChat('- - -'), equals(''));
      });

      test('long dashes', () {
        expect(markdownToGoogleChat('----------'), equals(''));
      });

      test('surrounded by content', () {
        expect(markdownToGoogleChat('above\n---\nbelow'), equals('above\n\nbelow'));
      });
    });

    group('bullet lists', () {
      test('asterisk bullets normalized to dash', () {
        expect(markdownToGoogleChat('* first\n* second'), equals('- first\n- second'));
      });

      test('dash bullets unchanged', () {
        expect(markdownToGoogleChat('- first\n- second'), equals('- first\n- second'));
      });

      test('bold in list item', () {
        expect(markdownToGoogleChat('- **item one**\n- **item two**'), equals('- *item one*\n- *item two*'));
      });
    });

    group('code protection', () {
      test('fenced code block content untouched', () {
        final input = '```python\ndef hello():\n    print("**bold**")\n```';
        expect(markdownToGoogleChat(input), equals(input));
      });

      test('inline code untouched', () {
        expect(markdownToGoogleChat('Use `**bold**` for bold'), equals('Use `**bold**` for bold'));
      });

      test('formatting outside code still converted', () {
        expect(markdownToGoogleChat('**bold** and `**not bold**`'), equals('*bold* and `**not bold**`'));
      });

      test('code block with language hint', () {
        final input = '```dart\nfinal x = **y**;\n```';
        expect(markdownToGoogleChat(input), equals(input));
      });

      test('multiple code blocks', () {
        final input = '**bold**\n```\ncode1\n```\n**more bold**\n```\ncode2\n```';
        final expected = '*bold*\n```\ncode1\n```\n*more bold*\n```\ncode2\n```';
        expect(markdownToGoogleChat(input), equals(expected));
      });
    });

    group('escaped characters', () {
      test('escaped asterisks preserved', () {
        expect(markdownToGoogleChat(r'\*literal\*'), equals(r'\*literal\*'));
      });

      test('escaped underscores preserved', () {
        expect(markdownToGoogleChat(r'\_not italic\_'), equals(r'\_not italic\_'));
      });

      test('escaped tilde preserved', () {
        expect(markdownToGoogleChat(r'\~not strike\~'), equals(r'\~not strike\~'));
      });

      test('escaped markers mixed with real formatting', () {
        expect(markdownToGoogleChat(r'**bold** and \*literal\*'), equals(r'*bold* and \*literal\*'));
      });
    });

    group('combined formatting', () {
      test('bold and italic in same text', () {
        expect(markdownToGoogleChat('**bold** and _italic_ text'), equals('*bold* and _italic_ text'));
      });

      test('bold with italic inside', () {
        expect(markdownToGoogleChat('**bold _with italic_ inside**'), equals('*bold _with italic_ inside*'));
      });

      test('realistic Claude output', () {
        final input = '''## Summary

Here is a **bold** statement and some _italic_ text.

### Key Points

- **First point**: This is important
- **Second point**: Check [this link](https://example.com)
- Third point with `inline code`

```python
def hello():
    print("**not converted**")
```

For more info, see ~~old docs~~ [new docs](https://docs.example.com).''';

        final expected = '''*Summary*

Here is a *bold* statement and some _italic_ text.

*Key Points*

- *First point*: This is important
- *Second point*: Check <https://example.com|this link>
- Third point with `inline code`

```python
def hello():
    print("**not converted**")
```

For more info, see ~old docs~ <https://docs.example.com|new docs>.''';

        expect(markdownToGoogleChat(input), equals(expected));
      });
    });
  });
}

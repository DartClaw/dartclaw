# Mascot favicon provenance

Source: `assets/logo-avatar-512-8bit.png`.

Regenerate the committed 16px and 32px PNG variants, plus the static 512px masthead copy, with:

```sh
cd dev/tools/mascot_favicon && dart pub get && dart run bin/generate.dart
```

The generator uses nearest-neighbor resizing so the mascot remains crisp.

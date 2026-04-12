#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

EMBEDDED_ASSETS="packages/dartclaw_server/lib/src/embedded_assets.dart"
EMBEDDED_SKILLS="packages/dartclaw_workflow/lib/src/embedded_skills.dart"

restore_assets_stub() {
  cat >"$EMBEDDED_ASSETS" <<'EOF'
import 'dart:convert';

const _encodedTemplates = <String, String>{};
const _encodedStaticAssets = <String, String>{};
final Map<String, String> embeddedStaticMimeTypes = {};

final Map<String, String> embeddedTemplates = {
  for (final entry in _encodedTemplates.entries) entry.key: utf8.decode(base64Decode(entry.value)),
};

final Map<String, List<int>> embeddedStaticAssets = {
  for (final entry in _encodedStaticAssets.entries) entry.key: base64Decode(entry.value),
};
EOF
}

restore_skills_stub() {
  cat >"$EMBEDDED_SKILLS" <<'EOF'
import 'dart:convert';

const _encodedSkills = <String, Map<String, String>>{};

final Map<String, Map<String, String>> embeddedSkills = {
  for (final skill in _encodedSkills.entries)
    skill.key: {for (final file in skill.value.entries) file.key: utf8.decode(base64Decode(file.value))},
};
EOF
}

restore_stubs() {
  restore_assets_stub
  restore_skills_stub
}

trap restore_stubs EXIT

mkdir -p build

dart run tool/embed_assets.dart
dart compile exe apps/dartclaw_cli/bin/dartclaw.dart -o build/dartclaw
echo "==> Build complete: build/dartclaw ($(du -h build/dartclaw | cut -f1))"

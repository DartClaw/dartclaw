#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
mkdir -p "$ROOT_DIR/.agent_temp"
TEST_ROOT="$(mktemp -d "$ROOT_DIR/.agent_temp/config-reference-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/dev/tools" "$TEST_ROOT/docs/guide" "$TEST_ROOT/schemas"
cp "$ROOT_DIR/dev/tools/render_config_reference.dart" "$TEST_ROOT/dev/tools/"
cp "$ROOT_DIR/dev/tools/config_reference_core_keys.txt" "$TEST_ROOT/dev/tools/"
cp "$ROOT_DIR/docs/guide/configuration.md" "$TEST_ROOT/docs/guide/"
cp "$ROOT_DIR/schemas/dartclaw.schema.json" "$TEST_ROOT/schemas/"
cp "$TEST_ROOT/dev/tools/config_reference_core_keys.txt" "$TEST_ROOT/core.base"
cp "$TEST_ROOT/docs/guide/configuration.md" "$TEST_ROOT/guide.base"

run_renderer() {
  (cd "$TEST_ROOT" && dart run dev/tools/render_config_reference.dart "$@")
}

expect_failure() {
  local expected="$1"
  shift
  local output
  if output="$(run_renderer "$@" 2>&1)"; then
    echo "renderer unexpectedly accepted fixture; expected: $expected" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "renderer failure did not contain '$expected': $output" >&2
    exit 1
  fi
}

run_renderer --check
run_renderer
cmp -s "$TEST_ROOT/guide.base" "$TEST_ROOT/docs/guide/configuration.md" || {
  echo "renderer is not idempotent" >&2
  exit 1
}

for mode in write check; do
  cp "$TEST_ROOT/core.base" "$TEST_ROOT/dev/tools/config_reference_core_keys.txt"
  printf '\nport  # duplicate fixture\n' >> "$TEST_ROOT/dev/tools/config_reference_core_keys.txt"
  [[ "$mode" == check ]] && expect_failure 'Duplicate core config key: port' --check || expect_failure 'Duplicate core config key: port'

  cp "$TEST_ROOT/core.base" "$TEST_ROOT/dev/tools/config_reference_core_keys.txt"
  printf '\nnot.a.real.path  # unknown fixture\n' >> "$TEST_ROOT/dev/tools/config_reference_core_keys.txt"
  [[ "$mode" == check ]] && expect_failure 'Unknown core config key: not.a.real.path' --check || expect_failure 'Unknown core config key: not.a.real.path'

  cp "$TEST_ROOT/core.base" "$TEST_ROOT/dev/tools/config_reference_core_keys.txt"
  printf '\nport\n' >> "$TEST_ROOT/dev/tools/config_reference_core_keys.txt"
  [[ "$mode" == check ]] && expect_failure 'Malformed core config key entry: port' --check || expect_failure 'Malformed core config key entry: port'

  awk '
    /^### Full Config Reference$/ { full = 1; next }
    /<!-- END GENERATED CONFIG REFERENCE -->/ { full = 0 }
    full && /^\| `/ {
      key = $0
      sub(/^\| `/, "", key)
      sub(/` \|.*$/, "", key)
      print key "  # count fixture"
      if (++count == 91) exit
    }
  ' "$TEST_ROOT/guide.base" > "$TEST_ROOT/dev/tools/config_reference_core_keys.txt"
  [[ "$mode" == check ]] && expect_failure 'Core config key count 91 exceeds the limit of 90.' --check || expect_failure 'Core config key count 91 exceeds the limit of 90.'
done

cp "$TEST_ROOT/core.base" "$TEST_ROOT/dev/tools/config_reference_core_keys.txt"
cp "$TEST_ROOT/guide.base" "$TEST_ROOT/docs/guide/configuration.md"
sed -i.bak 's/| `port` |/| `port-edited` |/' "$TEST_ROOT/docs/guide/configuration.md"
expect_failure 'docs/guide/configuration.md is out of date' --check
run_renderer
run_renderer --check

printf '\nFixture note outside generated region.\n' >> "$TEST_ROOT/docs/guide/configuration.md"
run_renderer --check

cp "$TEST_ROOT/guide.base" "$TEST_ROOT/docs/guide/configuration.md"
sed -i.bak 's/TCP port the HTTP server binds\./Fixture TCP port description./' "$TEST_ROOT/schemas/dartclaw.schema.json"
expect_failure 'docs/guide/configuration.md is out of date' --check
run_renderer
run_renderer --check

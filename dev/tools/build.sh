#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
VERSION_FILE="$ROOT_DIR/packages/dartclaw_server/lib/src/version.dart"
TARGET="${DARTCLAW_RELEASE_TARGET:-}"
SKIP_COMPILE="${DARTCLAW_BUILD_SKIP_COMPILE:-}"

stage_root="$(mktemp -d "${TMPDIR:-/tmp}/dartclaw-build.XXXXXX")"
cleanup() {
  rm -rf "$stage_root"
}
trap cleanup EXIT INT TERM

# Run the version sync from a copy outside the workspace: `dart run` inside the
# repo rebuilds the shared .dart_tool/native_assets.yaml (sqlite3 hooks), and a
# concurrently loading test-runner VM that reads the file mid-write aborts with
# "File not formatted as yaml". The tool imports only dart:io, so a detached
# copy runs hook-free.
cp "$ROOT_DIR/dev/tools/sync_version.dart" "$stage_root/"
(cd "$stage_root" && dart sync_version.dart "$ROOT_DIR")

version="$(sed -n "s/.*dartclawVersion = '\([^']*\)'.*/\1/p" "$VERSION_FILE" | head -n1)"
if [[ -z "$version" ]]; then
  echo "Unable to determine dartclawVersion from $VERSION_FILE" >&2
  exit 1
fi

platform_name() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux) echo "linux" ;;
    *) echo "$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
  esac
}

arch_name() {
  case "$(uname -m)" in
    x86_64 | amd64) echo "x64" ;;
    arm64 | aarch64) echo "arm64" ;;
    *) echo "$(uname -m)" ;;
  esac
}

target_os_name() {
  local target="$1"
  echo "${target%-*}"
}

target_arch_name() {
  local target="$1"
  echo "${target##*-}"
}

# Build the release binary with `dart build cli`, which runs the sqlite3 native
# build hooks and emits a bundle with the executable plus its bundled
# libsqlite3 in a sibling lib/. `dart compile exe` cannot be used: its
# build-hook detection classifies by the workspace-root pubspec (where sqlite3
# is absent), so it silently produces a binary with no sqlite native-asset
# mapping (dart-lang/sdk#62593). `dart build cli` cannot cross-compile, so each
# target must be built on a native runner for that OS/arch.
compile_binary() {
  local target_os="$1"
  local target_arch="$2"

  mkdir -p "$BUILD_DIR/bin"

  if [[ -n "$SKIP_COMPILE" ]]; then
    printf '#!/usr/bin/env sh\nprintf "%%s\\n" "%s"\n' "$version" > "$BUILD_DIR/bin/dartclaw"
    chmod 755 "$BUILD_DIR/bin/dartclaw"
    return
  fi

  if [[ "$target_os" != "$(platform_name)" || "$target_arch" != "$(arch_name)" ]]; then
    echo "Target $target_os-$target_arch requires a native $target_os-$target_arch runner" >&2
    exit 1
  fi

  local cli_stage="$stage_root/cli"
  (cd "$ROOT_DIR/apps/dartclaw_cli" && dart build cli -t bin/dartclaw.dart -o "$cli_stage")
  cp "$cli_stage/bundle/bin/dartclaw" "$BUILD_DIR/bin/dartclaw"
  cp -R "$cli_stage/bundle/lib" "$BUILD_DIR/lib"
}

sha256_file() {
  local path="$1"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

platform_stage="$stage_root/platform"

mkdir -p "$platform_stage/bin"
printf '%s\n' "$version" > "$platform_stage/VERSION"

release_os="$(platform_name)"
release_arch="$(arch_name)"
if [[ -n "$TARGET" ]]; then
  release_os="$(target_os_name "$TARGET")"
  release_arch="$(target_arch_name "$TARGET")"
fi
compile_binary "$release_os" "$release_arch"

cp "$BUILD_DIR/bin/dartclaw" "$platform_stage/bin/dartclaw"

platform_entries=(VERSION bin)
if [[ -d "$BUILD_DIR/lib" ]]; then
  cp -R "$BUILD_DIR/lib" "$platform_stage/lib"
  platform_entries+=(lib)
fi

platform_archive="$BUILD_DIR/dartclaw-v${version}-${release_os}-${release_arch}.tar.gz"
platform_sha="$platform_archive.sha256"

COPYFILE_DISABLE=1 tar --format=ustar --exclude='.DS_Store' --exclude='._*' -C "$platform_stage" -czf "$platform_archive" "${platform_entries[@]}"

printf '%s  %s\n' "$(sha256_file "$platform_archive")" "$(basename "$platform_archive")" > "$BUILD_DIR/SHA256SUMS.txt"

printf '%s  %s\n' "$(sha256_file "$platform_archive")" "$(basename "$platform_archive")" > "$platform_sha"

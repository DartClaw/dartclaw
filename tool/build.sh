#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_ENTRY="$ROOT_DIR/apps/dartclaw_cli/bin/dartclaw.dart"
VERSION_FILE="$ROOT_DIR/packages/dartclaw_server/lib/src/version.dart"

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

sha256_file() {
  local path="$1"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

copy_tree() {
  local source_dir="$1"
  local destination_dir="$2"

  if [[ ! -d "$source_dir" ]]; then
    echo "Missing expected source tree: $source_dir" >&2
    exit 1
  fi

  mkdir -p "$destination_dir"
  cp -R "$source_dir"/. "$destination_dir"/
}

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

stage_root="$(mktemp -d "${TMPDIR:-/tmp}/dartclaw-build.XXXXXX")"
cleanup() {
  rm -rf "$stage_root"
}
trap cleanup EXIT INT TERM

platform_stage="$stage_root/platform"
assets_stage="$stage_root/assets"
shared_root_name="dartclaw"

mkdir -p "$platform_stage/bin" "$platform_stage/share/$shared_root_name" "$assets_stage"
printf '%s\n' "$version" > "$platform_stage/VERSION"
printf '%s\n' "$version" > "$assets_stage/VERSION"

dart compile exe "$APP_ENTRY" -o "$BUILD_DIR/dartclaw"

cp "$BUILD_DIR/dartclaw" "$platform_stage/bin/dartclaw"

copy_tree "$ROOT_DIR/packages/dartclaw_server/lib/src/templates" "$platform_stage/share/$shared_root_name/templates"
copy_tree "$ROOT_DIR/packages/dartclaw_server/lib/src/static" "$platform_stage/share/$shared_root_name/static"
copy_tree "$ROOT_DIR/packages/dartclaw_workflow/skills" "$platform_stage/share/$shared_root_name/skills"
copy_tree "$ROOT_DIR/packages/dartclaw_workflow/lib/src/workflow/definitions" "$platform_stage/share/$shared_root_name/workflows"

copy_tree "$ROOT_DIR/packages/dartclaw_server/lib/src/templates" "$assets_stage/templates"
copy_tree "$ROOT_DIR/packages/dartclaw_server/lib/src/static" "$assets_stage/static"
copy_tree "$ROOT_DIR/packages/dartclaw_workflow/skills" "$assets_stage/skills"
copy_tree "$ROOT_DIR/packages/dartclaw_workflow/lib/src/workflow/definitions" "$assets_stage/workflows"

platform_archive="$BUILD_DIR/dartclaw-v${version}-$(platform_name)-$(arch_name).tar.gz"
asset_archive="$BUILD_DIR/dartclaw-assets-v${version}.tar.gz"
platform_sha="$platform_archive.sha256"
asset_sha="$asset_archive.sha256"

COPYFILE_DISABLE=1 tar --format=ustar -C "$platform_stage" -czf "$platform_archive" VERSION bin share
COPYFILE_DISABLE=1 tar --format=ustar -C "$assets_stage" -czf "$asset_archive" VERSION templates static skills workflows

{
  printf '%s  %s\n' "$(sha256_file "$platform_archive")" "$(basename "$platform_archive")"
  printf '%s  %s\n' "$(sha256_file "$asset_archive")" "$(basename "$asset_archive")"
} > "$BUILD_DIR/SHA256SUMS.txt"

printf '%s  %s\n' "$(sha256_file "$platform_archive")" "$(basename "$platform_archive")" > "$platform_sha"
printf '%s  %s\n' "$(sha256_file "$asset_archive")" "$(basename "$asset_archive")" > "$asset_sha"

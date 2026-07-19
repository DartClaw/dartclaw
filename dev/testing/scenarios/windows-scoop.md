# Windows Scoop Qualification

Qualify the rendered-manifest path used by the release workflow on Windows x64.

## Preconditions

- A qualified `dartclaw-v<version>-windows-x64.zip` and matching `.sha256`.
- Scoop and Git installed on the Windows host.
- The archive available over HTTP. A loopback server is sufficient before release.

## Procedure

1. Copy `package/scoop/dartclaw.json` into a temporary Git repository as `bucket/dartclaw.json`.
2. Replace only the temporary manifest's install-time URL with the archive URL and its placeholder hash with the
   archive's SHA256. Keep the canonical manifest unchanged.
3. Add the temporary repository as a Scoop bucket and install the bucket-qualified package:

   ```powershell
   scoop bucket add dartclaw-local <temporary-git-url>
   scoop install dartclaw-local/dartclaw
   dartclaw --version
   ```

4. Resolve the versioned app directory rather than Scoop's `current` junction, then verify bundled SQLite identity:

   ```powershell
   $current = (scoop prefix dartclaw).Trim()
   $appRoot = Join-Path (Split-Path $current -Parent) '<version>'
   & (Join-Path $appRoot 'bin\dartclaw.exe') release-sqlite-check `
     --expected-module (Join-Path $appRoot 'lib\sqlite3.dll')
   ```

5. Run `scoop update dartclaw`, then `scoop uninstall dartclaw` and remove the temporary bucket. Confirm the shim is
   gone.
6. After a tagged release publishes the hosted manifest, repeat the install against
   `https://github.com/DartClaw/scoop-dartclaw`. Save a local report under `.agent_temp/` if needed.

## Pass Criteria

- Bucket add, download, SHA256 validation, extraction, shim creation, version check, bundled SQLite/FTS5 check,
  update, uninstall, and cleanup all pass.
- The hosted path is release-ready only when the public bucket contains a rendered manifest whose URL resolves to the
  public Windows release asset.

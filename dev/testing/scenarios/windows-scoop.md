# Windows Scoop Qualification

Qualify the rendered-manifest path used by the release workflow on Windows x64.

## Preconditions

- Qualified `dartclaw-v<version>-windows-x64.zip` and `dartclaw-workflow-v<version>-windows-x64.zip`, each with its matching `.sha256`.
- Scoop and Git installed on a disposable Windows x64 host, with neither DartClaw package already installed.
- A source checkout matching the artifacts, with commands run from its root.
- The archive available over HTTP. A loopback server is sufficient before release.

## Procedure

1. Copy both manifests from `package/scoop/` into a temporary Git repository under `bucket/`.
2. Set each temporary manifest's install-time URL and hash to its corresponding archive URL and SHA256. Keep the
   canonical manifests unchanged.
3. Add the temporary repository as a Scoop bucket and install the bucket-qualified package:

   ```powershell
   scoop bucket add dartclaw-local <temporary-git-url>
   scoop install dartclaw-local/dartclaw dartclaw-local/dartclaw-workflow
   dartclaw --version
   dartclaw-workflow --version
   ```

4. Require both version commands to report the version being qualified. Resolve each versioned app directory rather
   than Scoop's `current` junction, then use the same bundled SQLite/FTS5 check as the Windows release build:

   ```powershell
   . ./dev/tools/build_windows.ps1
   $version = '<version>'
   foreach ($name in @('dartclaw', 'dartclaw-workflow')) {
     $current = (scoop prefix $name).Trim()
     if ($LASTEXITCODE -ne 0) { throw "Cannot resolve Scoop prefix for $name" }
     $appRoot = Join-Path (Split-Path $current -Parent) $version
     Invoke-WindowsBundledSqliteCheck -Executable (Join-Path $appRoot "bin/$name.exe") -BinaryName $name
   }
   ```

   Dot-sourcing loads the helper without running a build. It creates an empty temporary workspace, runs
   `rebuild-index`, checks the result, and cleans up. Creating the FTS5 table proves that the bundled SQLite loaded;
   no memory fixture is needed. This keeps corpus-format and Git line-ending handling out of the packaging audit.

5. Run `scoop update dartclaw dartclaw-workflow`, then `scoop uninstall dartclaw dartclaw-workflow` and remove the
   temporary bucket. Confirm both shims are gone. Clean up installed packages and the bucket even if a check fails.
6. After a tagged release publishes both hosted manifests, repeat steps 3–5 using bucket name `dartclaw` and
   `https://github.com/DartClaw/scoop-dartclaw`. Reuse the published archives and this procedure; save the outcome under
   `.agent_temp/`. Use local Windows for development checks; a hosted Windows x64 runner is needed only when no local
   native x64 host is available for final qualification.

## Pass Criteria

- For both packages: bucket add, download, SHA256 validation, extraction, shim creation, exact version check, bundled
  SQLite/FTS5 check, update, uninstall, and cleanup all pass.
- The hosted path is release-ready only when the public bucket contains both rendered manifests, each pointing to its
  matching public Windows release asset and checksum.

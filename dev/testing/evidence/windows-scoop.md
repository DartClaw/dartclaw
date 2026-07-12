# Windows Scoop Qualification Evidence

**Status**: LOCAL MANIFEST FLOW QUALIFIED; HOSTED INSTALL PENDING WINDOWS RELEASE AND PUBLICATION TOKEN

**Run timestamp**: `2026-07-12T16:56:19Z`
**Qualification workflow**: [GitHub Actions run 29201029703](https://github.com/DartClaw/dartclaw/actions/runs/29201029703)
**Host**: Microsoft Windows Server 2025 10.0.26100, GitHub `windows-latest`
**DartClaw version**: 0.20.1
**Source artifact workflow**: [GitHub Actions run 29181756146](https://github.com/DartClaw/dartclaw/actions/runs/29181756146)
**Source revision**: `d9b2e9d612fd0fdef1305553dccc15f43b2fd32e`
**Artifact SHA256**: `f34070ff167bc4ad60b0d0bc2eab00495129a6cb78cb0da4719dc806dcd9255a`
**Public bucket**: [DartClaw/scoop-dartclaw](https://github.com/DartClaw/scoop-dartclaw), scaffold commit `e69aa4ac83fba25930420aecb12dc1519c6a3510`
**Public bucket check**: `2026-07-12T16:53Z`, Microsoft Windows 11 Pro 10.0.26200 ARM64, PowerShell 5.1

## Results

| Check | Result | Evidence |
|---|---|---|
| Qualified artifact download | pass | Actions artifact `windows-x64-qualification` from run 29181756146 |
| Temporary Git bucket add | pass | `The dartclaw-local bucket was added successfully.` |
| Archive download and SHA256 | pass | `Checking hash of dartclaw-v0.20.1-windows-x64.zip ... ok.` |
| Install and shim | pass | Scoop installed DartClaw 0.20.1 and created the `dartclaw` shim |
| Version | pass | `VERSION_OK=0.20.1` |
| Bundled SQLite/FTS5 identity | pass | Loaded `C:\Users\runneradmin\scoop\apps\dartclaw\0.20.1\lib\sqlite3.dll`; FTS5 validation passed |
| Update | pass | Scoop reported every installed app at its latest version |
| Uninstall and cleanup | pass | Package and temporary bucket removed; no `dartclaw` shim remained |
| Public bucket availability | pass | Windows VM: `The dartclaw bucket was added successfully.` then `The dartclaw bucket was removed successfully.` |
| Hosted install | pending | v0.20.1 has no public Windows ZIP; the bucket intentionally has no manifest yet |

## Remaining Release Gate

Create a fine-grained token with `contents:write` limited to `DartClaw/scoop-dartclaw`, store it as
`SCOOP_BUCKET_TOKEN` on `DartClaw/dartclaw`, then confirm the first 0.21 tag publishes both the Windows ZIP and the
rendered bucket manifest. Repeat the hosted install procedure before calling Scoop release-ready.

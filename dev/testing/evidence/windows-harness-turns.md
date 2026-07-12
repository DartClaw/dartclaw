# Native Windows Harness-Turn Evidence

**Status**: QUALIFIED

**Run timestamps**: Claude `2026-07-12T07:18:23.2333374+02:00`; Codex `2026-07-12T07:18:23.2333374+02:00`
**Host**: Windows 11 Pro 10.0 build 26200, ARM64 (Parallels; Windows x64 application emulation)
**Windows user**: `TOBIASLFSTR7587\tobias` (`C:\Users\tobias`)
**DartClaw under test**: release artifact 0.20.1, built by GitHub Actions from
`ab26662eba008a63e33d77062a216b220d24d82f`; archive SHA256
`8bbdc5b76c294bc4ec130ca8c94c4db189e901d077051a57fb1ea5505ec379f4`.
**Claude**: Claude Code 2.1.207
**Codex**: codex-cli 0.139.0

The x64 artifact ran under Windows ARM64's x64 application emulation. This record qualifies only the
architecture-neutral provider transport slice; native x64 artifact, SQLite, installer, and core-runtime gates remain
separate. Both providers used fresh DartClaw server startups and completed through DartClaw's HTTP session API with a
stored assistant response of `pong`.

## Claude Result

- HTTP session: `8400a680-ef1b-4542-9d0c-f20ed786ad5f`; turn:
  `3d3752ff-760c-484b-9991-db71cf0ef91d`.
- DartClaw terminal state: `completed`; stored assistant response: `pong`.
- Provider: Claude Code 2.1.207.
- Qualification: **PASS**.

## Codex Result

- HTTP session: `4f7addb2-1659-41be-8559-56895a59fdc6`; turn:
  `1553aa0f-f23b-4ec3-8b93-70028addf6de`.
- DartClaw terminal state: `completed`; stored assistant response: `pong`.
- Provider: codex-cli 0.139.0.
- Qualification: **PASS**.

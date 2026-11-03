---
profile: channels
viewport: desktop
port: 3336
auth_token: devtoken0
---
# Scenario: Slack Setup From Manifest To First DM

Walks the owner from a shipped manifest to a first DM answered, on each of the two transports, and then reinstalls the app without two scopes to prove the degraded paths. The app-creation steps are the guide's, in [`docs/guide/slack.md`](../../../docs/guide/slack.md): "Socket Mode Setup to First DM" and "Events API Setup to First DM". This scenario cites them by number and adds only what to observe.

Mark each step as the file convention says: Owner steps are done by a person in Slack, Runner steps by an agent with HTTP, the CLI and the logs. Use a fresh workspace and follow only the guide: reading source to get unstuck is itself the result.

Preparation (Owner, once): make a persistent data directory, export it as `DARTCLAW_CHANNELS_DATA_DIR`, copy the seed into it (`cp -R dev/testing/profiles/channels/data/. "$DARTCLAW_CHANNELS_DATA_DIR/"`, which `run.sh` then reuses), and add a top-level `data_dir:` holding that directory's absolute path to its `dartclaw.yaml`. The server runs with that data directory, so `dartclaw secrets` and `dartclaw doctor` must address it too: run every `dartclaw secrets set` from the guide as `dartclaw --config "$DARTCLAW_CHANNELS_DATA_DIR/dartclaw.yaml" secrets set …`. `channels.slack.enabled` stays `false` in the seed; steps flip it only in that directory's `dartclaw.yaml`. Export `DARTCLAW_POSTGRES_URL` for a dedicated PostgreSQL 14+ database in every shell that starts the profile or runs the doctor, because otherwise `run.sh` starts a disposable database whose address no other shell sees. In this file `dartclaw` is `dart --packages=.dart_tool/package_config.json apps/dartclaw_cli/bin/dartclaw.dart`, run from the repository root. Server start: `bash dev/testing/profiles/channels/run.sh`. The private channel manual lists what only the owner can supply.

## S1: Socket Mode, Manifest To First DM

### Steps

1. Owner: record the time, then follow the guide's "Socket Mode Setup to First DM" steps 1 to 5 using `examples/slack/manifest-socket.yaml` unchanged. Record whether Slack imported the manifest without naming a field, and any field it named
2. Owner: in the data directory's `dartclaw.yaml`, set `channels.slack.enabled: true`, `mode: socket` and your member ID in `dm_allowlist`, leaving the credential references as the seed names them
3. Runner: start the profile with `bash dev/testing/profiles/channels/run.sh` and wait for `GET http://localhost:3336/health` to answer 200
4. Runner: run `dartclaw --config "$DARTCLAW_CHANNELS_DATA_DIR/dartclaw.yaml" doctor --json` and read the four `slack.*` rows
5. Owner: send the bot a DM from the Slack app's Messages tab and record the time the reply appears, then record the time the setup began
6. Runner: read the server log for the session and confirm no row or line contains a token-shaped value

### Expected

- Slack imports the manifest without naming a field, or the field it names is recorded for correction
- `slack.credentials`, `slack.auth`, `slack.scopes` and `slack.transport` are all `pass`, and `slack.scopes` lists no missing scope
- The DM is answered in a thread, with no source file read during setup
- The doctor's `slack.transport` row shows the last connect time
- The server log holds no `xoxb-`, `xapp-` or signing-secret value


## S2: Events API, Manifest To A Slow Turn

Stop the Socket Mode server first, so the app has one transport.

### Steps

1. Owner: follow the guide's "Events API Setup to First DM" steps 1 to 5 with `examples/slack/manifest-events.yaml`, using a public HTTPS address you control for the request URL. Do not write that address into any file in the repository
2. Owner: in the data directory's `dartclaw.yaml`, set `mode: events` and `signing_secret_credential: slack-signing` (the name the guide's step 5 stored the signing secret under)
3. Runner: start the profile
4. Owner: in **Event Subscriptions**, check the request URL status (guide step 7) and record whether it reads Verified
5. Runner: run the doctor as in S1 step 4; record `slack.transport` before and after the first DM
6. Owner: DM the bot "Run `sleep 6` in a shell, then answer done." so the turn outlasts Slack's 3-second acknowledgement window
7. Runner: count the bot's replies in that thread and read the server log for a retried event with the same event ID

### Expected

- The request URL shows Verified, which proves the `url_verification` answer
- `slack.transport` warns "no request arrived yet" before the DM and passes with the last verified request time after it
- Exactly one reply appears in the thread, and the log shows any retry acknowledged without a second turn
- The first DM is answered with `slack.credentials`, `slack.auth` and `slack.scopes` all `pass`


## S3: Reinstall Without `assistant:write` And `files:read`

Run on Socket Mode: restore the S1 configuration first.

### Steps

1. Owner: copy `examples/slack/manifest-socket.yaml`, delete `assistant:write` and `files:read` from `oauth_config.scopes.bot`, update the app from the copy, reinstall it and store the new bot token under the same credential name
2. Runner: restart the profile, then run the doctor as in S1 step 4
3. Owner: DM the bot a question and note how long the reply takes against the S1 reply
4. Runner: read the server log for the status call and for the stream start for that turn, and count the replies in the thread
5. Owner: attach a small text file to a DM and send it with the question "What is in this file?"
6. Owner: restore the full scopes by reinstalling from the shipped manifest and storing the token again

### Expected

- `slack.scopes` is `fail` and names both `assistant:write` and `files:read`
- The reply arrives in the same time as in S1, so the failed status call never delayed the turn
- The log names the failed status call as a warning, and one complete reply is in the thread whether or not the stream started
- The reply to the file names the `files:read` scope, and the file's text is not in the answer
- After the reinstall in step 6 the doctor returns to all `pass`

---
profile: governance
viewport: desktop
port: 3337
auth_token: devtoken0
---
# Scenario: Governance Enforcement

Validates governance pipeline enforcement using the governance testing profile (global rate limit 5/60s, daily budget 10K tokens, budget warn mode). The profile startup seeds the current UTC day to 8,000 tokens used so the first turn can deterministically trigger a budget warning. The scenario then exercises warning emission, accepted sends in warn mode, and observable global deferral using the current API/event surface.

Server should be running: `bash dev/testing/profiles/governance/run.sh`

## S1: First Turn Crosses the Warning Threshold but Still Proceeds

The governance profile starts with the current UTC day seeded to 8,000 of 10,000 tokens used. The next turn should record a budget-warning marker while still allowing the send to proceed.

### Steps

1. Create a new session with the admin token:
   ```
   curl -s -X POST http://localhost:3337/api/sessions \
     -H "Authorization: Bearer devtoken0" \
     -H "Content-Type: application/json" \
     -d '{}'
   ```
2. Record the session ID from the response
3. Send a message to the new session using the implemented send route:
   ```
   curl -s -X POST http://localhost:3337/api/sessions/<session-id>/send \
     -H "Authorization: Bearer devtoken0" \
     -H "Content-Type: application/json" \
     -d '{"message": "Hello, say exactly: pong"}'
   ```
4. Inspect `dev/testing/profiles/governance/data/kv.json` after the send completes:
   ```bash
   TODAY=$(date -u +%Y-%m-%d)
   jq --arg k "usage_daily:$TODAY" '.[$k].value | fromjson | .budget_warning_posted_at' \
     dev/testing/profiles/governance/data/kv.json
   ```
   Note: KvService stores the daily aggregate as a JSON-encoded string inside a `"value"` field. The `budget_warning_posted_at` marker is inside that string — a plain `cat` will not show it as a top-level key.

### Expected

- Session creation returns HTTP 201 with a JSON body containing an `id` field
- Message send returns HTTP 200
- The response body is an HTML fragment containing a stream URL under `/api/sessions/<session-id>/stream?turn=...`
- The jq command returns an ISO 8601 timestamp string (not `null`) — confirming `budget_warning_posted_at` was written
- The send is allowed to proceed because budget enforcement is in `warn` mode, not `block` mode


## S2: Later Sends Still Succeed After the Warning Threshold Is Crossed

A later session creation plus send should still be accepted after the warning has already been emitted for the day.

### Steps

1. Create a fresh session with the admin token and record its id
2. Send one message to that session with `POST /api/sessions/<id>/send`
3. Observe the HTTP status code and response body

### Expected

- Session creation returns HTTP 201 with a JSON body containing an `id` field
- The follow-up send still returns HTTP 200 after the warning threshold has already been crossed
- The response still contains a valid `/api/sessions/<id>/stream?turn=...` URL
- The request is not blocked by budget enforcement


## S3: Sixth Cross-Session Turn Is Deferred by the Global Rate Limit

The governance profile sets a global rate limit of 5 turns per minute. Create six separate sessions, send one message to the first five immediately, then time the sixth request. The sixth should wait for capacity instead of failing with an immediate rejection.

> **Timeout note**: The global rate limiter holds the HTTP connection open while waiting for capacity. With a 1-minute window, the sixth request may block for up to 60 seconds. Use `--max-time 90` in curl (or equivalent) so the client does not time out before the server can respond.

### Steps

1. Create six fresh sessions with the admin token and record all six ids
2. Send one short message to sessions 1 through 5 in rapid succession using `POST /api/sessions/<id>/send`
3. Immediately send a first message to session 6 and measure the elapsed wall-clock time for that request
4. Record the HTTP status code and response body for the session-6 request

### Expected

- Messages 1 through 5 return HTTP 200 and produce valid stream URLs
- The session-6 request eventually returns HTTP 200 rather than a 429
- The session-6 request takes noticeably longer than the first five requests because it waits for global capacity
- The session-6 response still contains a valid `/api/sessions/<id>/stream?turn=...` URL once it completes

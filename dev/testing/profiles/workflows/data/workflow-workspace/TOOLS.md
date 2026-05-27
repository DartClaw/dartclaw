# Workflow Tools

## API Endpoints (for verification)

```bash
TOKEN=$(cat dev/testing/profiles/workflows/data/gateway_token)

# List workflow definitions
curl -H "Authorization: Bearer $TOKEN" http://localhost:3333/api/workflows/definitions | jq

# List skills
curl -H "Authorization: Bearer $TOKEN" http://localhost:3333/api/skills | jq '.count'

# List tasks
curl -H "Authorization: Bearer $TOKEN" http://localhost:3333/api/tasks | jq

# Get task details
curl -H "Authorization: Bearer $TOKEN" http://localhost:3333/api/tasks/<id> | jq

# List workflow runs
curl -H "Authorization: Bearer $TOKEN" http://localhost:3333/api/workflows | jq
```

## Development Commands

```bash
dart test packages/<package>              # Run tests
dart test packages/<package> -t integration  # Integration tests
dart analyze packages/<package>           # Static analysis
dart format <file>                        # Format
```

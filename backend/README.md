# incident_backend

Receives a captured production incident from the Flutter SDK, has a model
explain it, files a Jira Bug, and posts to Slack.

## Run it

Configuration comes from the environment; nothing has a default and a missing
secret stops the process rather than starting it half-wired.

```bash
set -a && . ../.env.local && set +a
export SYMBOLS_DIR=$PWD/../build/symbols
dart run bin/server.dart
```

`GET /health` answers `ok`. `POST /ingest` takes the SDK's JSON array behind
`Authorization: Bearer $INGEST_APP_TOKEN`.

## Docker

```bash
docker build -t incident-backend .
docker run --rm -p 8787:8787 --env-file ../.env.local \
  -v "$PWD/../build/symbols:/symbols" -v incident-state:/state incident-backend
```

The image is the deploy artifact: the same one runs on Render or Azure
Container Apps without a code change.

## Symbols

Release stack traces are meaningless until decoded. The app must be built with

```bash
--split-debug-info=build/symbols/$(git rev-parse --short HEAD)
```

The per-commit subdirectory is not optional — it is how a trace is matched to
the build that produced it. Flat output silently yields unsymbolicated tickets.

## Stage runbook

1. Start the backend. Confirm the startup line names the right Jira project
   and model.
2. `curl localhost:8787/health` → `ok`.
3. `adb reverse tcp:8787 tcp:8787` if demoing on a tethered phone. The
   emulator needs nothing; it reaches the host as `10.0.2.2`.
4. Fire one incident before going on stage. It warms every path and proves
   Jira and Slack are reachable from the venue's network.
5. Delete the resulting ticket and `rm` the dedupe file, so the live run files
   a fresh one rather than commenting on the rehearsal's.

That last step matters: dedupe deliberately survives a restart, so without it
the live tap adds a comment to an existing ticket instead of creating the
ticket the audience is waiting to see.

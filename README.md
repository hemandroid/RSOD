# incident_sdk

Production failure tracing for Flutter. When a release build breaks, the SDK gathers the
evidence, an AI analyses it, a Jira ticket is created with reproduction steps and a root cause,
and the team is notified on Slack — with no action from the user.

The point: **a customer should never have to report your bug.** A one-star review or a support
email costs you the customer and days of turnaround. The app should file its own ticket first.

Built for the FlutterCon India 2026 session
*Beyond Crashlytics: Building Autonomous Incident Intelligence for Flutter.*

## Integration

```dart
void main() {
  IncidentSDK.init(endpoint: '...', appToken: '...');
  runApp(const MyApp());
}
```

## Layout

| Path | What it is |
|---|---|
| `packages/incident_sdk/` | The SDK — capture hooks, context collectors, disk-first queue, uploader |
| `docs/` | Plans, the talk brief, and the input checklist — start at [docs/README.md](docs/README.md) |
| `packages/rsod/`, `lib/` | Earlier red-screen experiment, kept as a crash-trigger harness during development |

## Status

In active development against a 5-day build plan. See [docs/PLAN_5_DAY.md](docs/PLAN_5_DAY.md).

# incident_sdk

Production failure tracing for Flutter. When a release build breaks, the SDK gathers the
evidence, an AI analyses it, a Jira ticket is created with reproduction steps and a root cause,
and the team is notified on Slack — with no action from the user.

The point: **a customer should never have to report your bug.** A one-star review or a support
email costs you the customer and days of turnaround. The app should file its own ticket first.

Built for the FlutterCon India 2026 session
*Beyond Crashlytics: Building Autonomous Incident Intelligence for Flutter.*

## Repositories

- **[github.com/hemandroid/RSOD](https://github.com/hemandroid/RSOD)**: the Flutter demo app and the `incident_sdk` package (this repository)
- **[github.com/hemandroid/incident-backend](https://github.com/hemandroid/incident-backend)**: the backend: symbolicator, dedupe, analyser, Jira filer, Slack notifier

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
| `lib/` | Nimbus, the demo store app used on stage to trigger network, navigation and runtime failures |

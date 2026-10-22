# incident_sdk

Production failure tracing for Flutter. When a release build breaks, the SDK gathers the
evidence, an AI analyses it, a Jira ticket is created with reproduction steps and a root cause,
and the team is notified on Slack — with no action from the user.

The point: **a customer should never have to report your bug.** A one-star review or a support
email costs you the customer and days of turnaround. The app should file its own ticket first.

Built by Kamal Shree and Hema Sai Charan Kothamasu for the flutterCon India 2026 session
*Beyond Crashlytics: Building Autonomous Incident Intelligence for Flutter.*

## Repositories

- **[github.com/hemandroid/RSOD](https://github.com/hemandroid/RSOD)**: the Flutter demo app and the `incident_sdk` package (this repository)
- **[github.com/hemandroid/incident-backend](https://github.com/hemandroid/incident-backend)**: the backend: symbolicator, dedupe, analyser, Jira filer, Slack notifier

You need both to see a ticket appear: this repository captures the failure on the device, and the
backend turns it into a Jira Bug and a Slack message.

## How it works

```
Flutter app + incident_sdk                      incident-backend
──────────────────────────                      ──────────────────────────────────────────
failure caught  ->  encrypted to disk  ->  POST /ingest  ->  symbolicate -> fingerprint -> dedupe
                    (AES-GCM, ≤512 KB)     (Bearer token)                                    |
                                                                        new fingerprint only v
                                                              model analysis -> Jira Bug -> Slack
```

1. **Catch.** `FlutterError.onError` and `PlatformDispatcher.instance.onError` are chained (never
   replaced), plus a UI-thread watchdog for freezes and `IncidentSDK.report` for handled failures.
2. **Collect.** Every incident carries the same context, whichever way the app broke: the last
   100 log breadcrumbs (capped at 16 KB), the last 20 routes, the last 20 HTTP calls with URLs and
   headers redacted, device details, a screenshot (≤128 KB, masked on the device) and the build's
   commit.
3. **Queue.** The incident is written to disk, encrypted, before anything touches the network, so
   a crash that kills the process still ships on the next launch.
4. **Upload.** A separate loop posts pending incidents in batches over HTTPS.
5. **File.** The backend decodes the obfuscated release stack trace, skips duplicates, asks a model
   for a root cause, repro steps, severity and a before/after code fix, then files the Jira Bug
   and posts the Slack alert. The screenshot goes onto the Jira issue as an attachment; it is never
   sent to the model.

In our rehearsals the ticket was in Jira between 13 and 60 seconds after the crash.

## What's in this repository

| Path | What it is |
|---|---|
| `packages/incident_sdk/` | The SDK: capture hooks, collectors, encrypted disk queue, uploader, UI watchdog, `IncidentMask` |
| `lib/` | Nimbus, the demo store app used on stage to break things on purpose |
| `test/` | Widget and catalogue tests for the demo app |
| `dart_defines.example.json` | Template for the build-time settings the app reads |
| `.vscode/launch.json` | Run configurations: debug and release, against a local or a cloud backend |

## Run the demo app

**You need:** Flutter stable (built with 3.44, Dart 3.10), an Android emulator or device, and a
running [incident-backend](https://github.com/hemandroid/incident-backend). Its README covers the
Jira, Slack and model settings. The demo has been verified on Android.

**1. Configure.** Copy the template and fill it in. The copy is gitignored; keep it that way,
because it holds the ingest token.

```bash
cp dart_defines.example.json dart_defines.local.json
```

| Key | What to put there |
|---|---|
| `INCIDENT_ENDPOINT` | The backend's full ingest URL. From the Android emulator, a backend on your laptop is `http://10.0.2.2:8787/ingest` |
| `INCIDENT_APP_TOKEN` | The same value as `INGEST_APP_TOKEN` in the backend's environment, or every upload is rejected |
| `INCIDENT_ALLOW_INSECURE` | `true` only for a plain-`http` local backend. Otherwise the SDK refuses anything but HTTPS |
| `USE_LIVE_CATALOGUE` | `true` loads real products from [DummyJSON](https://dummyjson.com) through the SDK's HTTP client; `false` uses built-in mock data |
| `COMMIT_SHA` | The key the backend uses to find this build's symbols. Must match the symbols folder name below |

There are no defaults: a missing endpoint or token stops the app at launch, rather than shipping a
build that quietly reports to nowhere.

**2. Run in release mode.** Release is the mode that matters: it strips asserts and obfuscates the
stack trace, which is exactly what the backend has to undo.

```bash
flutter run --release \
  --dart-define-from-file=dart_defines.local.json \
  --split-debug-info=build/symbols/dev \
  --obfuscate
```

The symbols subfolder (`dev` here) must equal `COMMIT_SHA`. Copy `build/symbols/<COMMIT_SHA>/`
into the backend's `SYMBOLS_DIR` so it can decode the trace. If the symbols do not come from this
exact build, the backend still files the ticket, but with function names that look right and are
wrong. In VS Code, the same commands are the **Nimbus — release** entries in the Run panel.

## Failures you can trigger

Open the **Chaos** tab. The switches live in memory only, so a restart disarms all of them: arm a
fault, then trigger it in the same session.

| Class | How to trigger it | What you see |
|---|---|---|
| Network | Arm **Payment API down** (needs `USE_LIVE_CATALOGUE=true`), then **Reload** on the Store tab | Requests fail for real and the store keeps showing its on-device cache. The failed calls ride along on the next incident's ticket |
| Navigation | Orders tab, then the **Track shipment** button on any order | The button pushes a route the app never registered, and the app falls to its crash screen |
| Runtime crash | Arm **Checkout session expired**, then Cart → Checkout → **Pay** | A null dereference in the payment path, and the crash screen |
| Red screen | Arm **Remote flag missing**, then **Reload** on the Store tab | A cast fails while the list is building, and Flutter's error widget appears in place of the list |
| Handled failure | Arm **Catalogue returns nothing**, then **Reload** | The user sees an empty state; the team still gets a ticket, via `IncidentSDK.report` |
| Data bug | Arm **Order history has duplicates**, then open a duplicated order | `Bad state: Too many elements` |
| Freeze (ANR) | **Rebuild local index** | The UI thread blocks for about 7 seconds; the watchdog files it, with an intentionally empty stack trace |
| Off-isolate error | **Sync in background** | An unhandled exception outside the framework, caught by the second hook |

Each one becomes a Jira Bug carrying the trace, breadcrumbs, routes, network calls, device details
and screenshot, plus a Slack message linking to it. Repeats of the same failure are deduplicated
into one ticket.

## Use incident_sdk in your own app

The package is not on pub.dev. Depend on it from this repository:

```yaml
dependencies:
  incident_sdk:
    git:
      url: https://github.com/hemandroid/RSOD.git
      path: packages/incident_sdk
```

Initialise it before `runApp`, then wire the three collectors only your app can provide:

```dart
import 'package:http/http.dart' as http;
import 'package:incident_sdk/incident_sdk.dart';

final routes = RouteHistoryCollector();
final network = NetworkCollector();
final screenshots = ScreenshotCollector();
final client = IncidentHttpClient(network, inner: http.Client()); // use for your API calls

void main() {
  IncidentSDK.init(
    endpoint: const String.fromEnvironment('INCIDENT_ENDPOINT'),
    appToken: const String.fromEnvironment('INCIDENT_APP_TOKEN'),
    collectors: [routes.collector, network.collector],
    screenshots: screenshots,
  );
  runApp(
    RepaintBoundary(
      key: screenshots.boundaryKey,
      child: MaterialApp(navigatorObservers: [routes], home: const HomePage()),
    ),
  );
}
```

- **Mask anything sensitive.** Wrap card numbers, addresses and similar fields in
  `IncidentMask(child: ...)`. The block is painted over before the screenshot is taken, so the
  real pixels never reach the image. Masking is opt-in: nothing finds sensitive UI for you.
- **Leave breadcrumbs.** `IncidentSDK.log('checkout: payment started')` adds a line the model
  reads when it explains the failure.
- **Report handled failures.** `IncidentSDK.report(error, stack, context: '...')` files a ticket
  for something you caught but still need to fix.
- **Build with the commit.** Pass `--dart-define=COMMIT_SHA=$(git rev-parse HEAD)` together with
  `--split-debug-info=build/symbols/$(git rev-parse HEAD) --obfuscate`, and give that folder to
  the backend. Without it, release traces arrive undecodable.
- **Other options** on `IncidentSDK.init`: `maxPending` (default 50 queued incidents),
  `enableUiWatchdog` and `uiWatchdogThreshold` (default 5 seconds), and `allowInsecureEndpoint`
  (local development only).

The SDK chains onto error handlers that are already installed instead of replacing them, so
another tool's handler keeps running.

## Tests

```bash
flutter test                                    # demo app: 24 tests
cd packages/incident_sdk && flutter test        # SDK: 183 tests
```

## What this is not

This is a working reference implementation, not a product. The pattern is ready to use; the code
has not had years of production hardening. In particular:

- Every ticket is assigned to one owner configured on the backend. Routing to whoever owns the
  code that broke is not built.
- The ticket carries a suggested before/after fix, but nothing applies it or opens a pull request.
- We measured the time from crash to a triaged ticket, not the time to a fix.
- Screenshot masking only covers what you wrap in `IncidentMask`.

## License

Apache License 2.0. See [LICENSE](LICENSE).

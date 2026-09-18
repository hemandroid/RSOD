# rsod_demo — Project Purpose

## One-line purpose

`rsod_demo` is the companion repository for a technical talk prepared for FlutterCon 2026. It
exists to demonstrate, live and on stage, how to replace Flutter's default "Red Screen of Death"
with a user-friendly error screen and route every caught error to analytics — packaged as
**`rsod`**, a dependency-free Flutter package in `packages/rsod/`.

Two audiences use this repo, and they want different things from it:

- **Talk attendees** want the before/after moment: the red screen, then the handled screen, then
  the analytics event in the console.
- **Anyone adopting the idea afterwards** wants `packages/rsod/` and a three-line integration.

The repository serves both, which explains most of its shape — including the parts that look
redundant.

## The problem the talk addresses

Flutter's default error surface fails in two directions:

1. **In debug**, a widget build failure paints a raw red screen with a stack trace — useful to the
   developer, unusable as a product surface, and alarming in a demo or a screenshot.
2. **In release**, the same failure paints a silent grey box: no explanation, no recovery action,
   and no record that anything went wrong.

`rsod` closes both gaps with one initialization call. It installs a custom `ErrorWidget.builder`,
hooks `FlutterError.onError` and `PlatformDispatcher.instance.onError`, and forwards every error
to an `AnalyticsService` the host app supplies (Firebase, Sentry, Mixpanel, or the built-in
console mock).

## What the repository contains

### 1. The package — `packages/rsod/` (what the talk is selling)

| File | Role |
|---|---|
| [lib/rsod.dart](packages/rsod/lib/rsod.dart) | Public barrel export — the single import consumers use |
| [lib/src/rsod.dart](packages/rsod/lib/src/rsod.dart) | `RSOD` facade: `initialize()`, `logError()`, `isInitialized` |
| [lib/src/error_handler_service.dart](packages/rsod/lib/src/error_handler_service.dart) | Installs the framework error hooks; defines `CustomErrorWidget`, the full-screen replacement for the red screen |
| [lib/src/analytics_service.dart](packages/rsod/lib/src/analytics_service.dart) | `AnalyticsService` interface + `MockAnalyticsService` console implementation |
| [lib/src/custom_error_screen.dart](packages/rsod/lib/src/custom_error_screen.dart) | `CustomErrorScreen`, a reusable error page for manual use (`fromException`, `onRetry`, `onGoHome`) |
| [lib/src/demo/rsod_demo_page.dart](packages/rsod/lib/src/demo/rsod_demo_page.dart) | Interactive page for triggering errors and comparing handled vs. unhandled behaviour |
| [example/main_example.dart](packages/rsod/example/main_example.dart) | Standalone usage example |

Three design constraints are visible in the code and are worth stating out loud during the talk:
**no third-party dependencies** (Flutter SDK only), **analytics is an interface, never a vendor**,
and **behaviour differs by build mode** — debug shows the exception and stack trace, release shows
"Oops! Something went wrong" plus a retry affordance, and both log to analytics.

### 2. The demo app — `lib/` (what runs on the projector)

- [lib/main.dart](lib/main.dart) — the entry point. Calls `RSOD.initialize()` before `runApp()`,
  then presents a counter screen with three stage-ready buttons: open the comparison demo, log a
  manual error via `RSOD.logError()`, and throw a live exception.
- [lib/demo/error_comparison_demo.dart](lib/demo/error_comparison_demo.dart) — **the centrepiece
  of the demo.** It toggles the custom handler on and off at runtime and keeps a timestamped,
  on-screen log, so the default red screen and the `rsod` screen can be shown back to back without
  a restart or a code edit. The on-screen log matters on a projector, where a terminal usually
  is not visible.
- [lib/demo/demo_2/final_demo.dart](lib/demo/demo_2/final_demo.dart) — a self-contained counter
  app wired to the package: "what this looks like in a normal app", for the closing slide.
- `lib/services/` and `lib/widgets/` — copies of the package sources that predate the extraction
  into `packages/rsod/` (see "Current state" below).

`android/` and `ios/` are stock Flutter scaffolding. `test/` holds the default counter smoke test
only.

## The integration story being taught

```dart
import 'package:rsod/rsod.dart';

void main() {
  RSOD.initialize();          // or: RSOD.initialize(analyticsService: MyService())
  runApp(const MyApp());
}
```

That is the entire contract, and it is the talk's headline claim. Everything else in the package —
`CustomErrorScreen`, `RSOD.logError()`, `RSODDemoPage` — is optional surface for manual error
handling and testing.

## Suggested demo order

1. Run the app, toggle the handler **off** in the comparison demo, trigger a widget error — the
   red screen, in front of the audience.
2. Toggle **on**, trigger the same error — the handled screen, and the analytics line in the log.
3. Show `main.dart`: three lines is the whole integration.
4. Show `AnalyticsService` and swap in the Firebase or Sentry implementation from the package
   README to make the "no vendor lock-in" point.
5. Close on `final_demo.dart` as the realistic end state.

## Current state

The package works and is integrated. The repository around it carries refactor residue, which is
harmless for a demo but worth knowing before anyone reads it as reference code — or before a
sharp-eyed attendee opens the repo during the talk.

**Affects the demo — worth deciding on before the event:**

- **The comparison demo does not exercise the shipped package.**
  [lib/demo/error_comparison_demo.dart](lib/demo/error_comparison_demo.dart) imports
  `../services/…`, the pre-extraction copies, not `package:rsod`. Behaviourally near-identical, so
  the demo looks right — but if anyone opens the file on stage, the import contradicts the claim
  that the package is doing the work. Repointing the imports at `package:rsod/rsod.dart` is a
  small change.
- **`showDebugInfo` is accepted but unused.** `RSOD.initialize(showDebugInfo: …)` stores nothing
  and never reaches `CustomErrorWidget`; debug detail is gated on `kReleaseMode` alone. It appears
  in the README as a configuration option, so it is a plausible audience question.
- **Async errors are swallowed.** `PlatformDispatcher.instance.onError` returns `true`
  unconditionally, marking every uncaught async error handled once it has been logged. Defensible,
  but it is a deliberate policy the talk should name rather than leave implicit.

**Cosmetic — only matters if the repo is published alongside the talk:**

- `lib/widgets/custom_error_screen.dart` is entirely commented out; `lib/services/` duplicates the
  package sources.
- Ten Markdown files at the root cover the same package from different angles.
  `FLOW_DIAGRAM.txt`, `INTEGRATION_COMPLETE.md` and `lib/demo/demo_2/README.md` are empty.
- Several docs cite an absolute path from another machine (`/Users/c21866e/…`) and a stale
  location for the counter demo (`packages/rsod/lib/src/demo_2/final_demo.dart`; it is actually
  `lib/demo/demo_2/final_demo.dart`).
- `packages/rsod/pubspec.yaml` and its README still carry `yourusername`,
  `support@example.com` and `[Your Name]`. The root `README.md` is untouched Flutter boilerplate —
  the first thing a visitor from the talk will see.
- Test coverage is the default counter smoke test; nothing exercises the error handling itself.

## Summary

Treat `packages/rsod/` as the artifact and everything else as the stage set. The repository's
purpose is to make one argument convincing in a conference slot: Flutter error handling can be
presentable in release, observable in analytics, and cost three lines to adopt.

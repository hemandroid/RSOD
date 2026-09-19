import 'dart:async';

import 'package:flutter/widgets.dart';

/// Called once, on recovery, with how long the UI thread was stalled.
///
/// Never called while the thread is actually blocked — the code that would
/// call it is running on that same thread — only after it frees up again.
///
/// `IncidentCapture.reportStall` has this shape, so the production wiring is
/// `UiWatchdog(onStall: capture.reportStall)`.
typedef StallCallback = void Function(Duration stallDuration);

/// Detects a blocked UI thread — Android's ANR class of failure — which no
/// Flutter error hook ever reports, because nothing throws and no callback
/// fires while the thread is stuck.
///
/// The mechanism: a cheap periodic [Timer] runs on the same event loop as
/// widget building, layout and gesture handling. If that loop is blocked by
/// synchronous work, the timer's own callback is delayed by exactly the same
/// amount, because Dart cannot run it any sooner. A heartbeat scheduled every
/// [heartbeatInterval] that actually lands 6 seconds later proves the loop
/// was stuck for ~6 seconds — the stall is measured, not observed directly,
/// which is also why it can only be recorded afterwards: the queue write
/// this class ultimately triggers needs the very thread that was frozen.
///
/// A backgrounded or suspended app is not a stalled one — a paused app can
/// legitimately go seconds or hours without a frame — so [start] also
/// listens for lifecycle changes and discounts any time spent outside
/// [AppLifecycleState.resumed] from the measurement entirely, rather than
/// letting it accumulate toward the threshold.
///
/// **Known, accepted gap:** [_tick] only checks whether the app is
/// foreground *at the moment the tick runs*, not whether it was foreground
/// for the entire gap being measured. A genuine freeze that starts while
/// resumed, where the OS delivers the "went to background" lifecycle message
/// before the queued heartbeat is processed once the thread frees up, reads
/// as a background transition and is discarded rather than reported. This is
/// deliberate, not an oversight: false positives (a suppressed app read as
/// stalled) are the risk this class exists to avoid, and are worse for a
/// team's Jira than an occasional false negative at exactly this boundary.
class UiWatchdog extends WidgetsBindingObserver {
  UiWatchdog({
    required this.onStall,
    this.threshold = const Duration(seconds: 5),
    this.heartbeatInterval = const Duration(seconds: 1),
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? _newStopwatchElapsed();

  /// Reports the recovered stall. See [StallCallback].
  final StallCallback onStall;

  /// Anything shorter is normal jank, not worth a ticket. The default tracks
  /// Android's own ~5s "Application Not Responding" window, so what this
  /// reports lines up with what the OS itself would already be flagging.
  final Duration threshold;

  /// How often the heartbeat runs when nothing is wrong. This is a plain
  /// [Timer.periodic], not a busy-wait — the cost when healthy is one timer
  /// callback per interval — and it bounds how precisely a stall's duration
  /// is measured, not how the stall is detected.
  final Duration heartbeatInterval;

  /// Monotonic ticks only — never wall-clock time. A [Stopwatch]-backed
  /// source cannot jump: it is immune to NTP correction, manual clock
  /// changes and DST transitions, all of which move [DateTime.now] in ways
  /// that have nothing to do with whether the UI thread actually ran. Using
  /// wall-clock time here would let a forward clock jump manufacture a false
  /// stall with zero real blocking, or let a backward jump hide a genuine
  /// one — exactly the false-positive/false-negative pair this class exists
  /// to avoid. (A wall-clock *timestamp*, for "when" the stall happened
  /// rather than "how long", is a separate concern and already handled
  /// downstream: `IncidentCapture.report` stamps `capturedAt` with real
  /// `DateTime.now()` at the moment [onStall] calls it.)
  final Duration Function() _elapsed;

  Timer? _timer;
  Duration? _lastTick;
  bool _foreground = true;

  /// Starts the heartbeat and begins tracking lifecycle changes. Call once,
  /// after the widgets binding exists.
  ///
  /// Idempotent — a second call is a no-op — so wiring this into an app's
  /// startup path twice (a hot restart, a duplicate `init`) cannot leave two
  /// timers running and double-report the same stall.
  ///
  /// "One stall, one report" for a *real* stall also leans on a documented
  /// [Timer.periodic] guarantee that this file's unit tests cannot exercise
  /// directly, because they drive [_tick] through [checkNow] rather than a
  /// live timer: when the callback runs long and blocks past the interval,
  /// Dart fires it again only once, as soon as the loop is free — it never
  /// queues up every interval that was missed and fires them back-to-back.
  /// Without that guarantee a long freeze could in principle report several
  /// times on recovery instead of once. The unit tests instead prove the
  /// narrower claim that *this class's own logic* only reports once per gap
  /// and resets its baseline immediately after — which is what [checkNow]
  /// can exercise without a live [Timer].
  void start() {
    if (_timer != null) return;
    _lastTick = _elapsed();
    WidgetsFlutterBinding.ensureInitialized().addObserver(this);
    _timer = Timer.periodic(heartbeatInterval, (_) => _tick());
  }

  /// Stops the heartbeat. Safe to call even if [start] was never called, or
  /// was already stopped.
  void stop() {
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed && !_foreground) {
      // Whatever time passed while backgrounded was not a stall. Restart the
      // baseline here instead of measuring from the tick before backgrounding,
      // or every suspend/resume would read as a multi-second freeze.
      _lastTick = _elapsed();
    }
    _foreground = resumed;
  }

  /// Runs one heartbeat check immediately, without waiting for [Timer].
  ///
  /// This is the test seam: a real stall takes real time to reproduce, so
  /// tests drive detection by advancing an injected elapsed-time function and
  /// calling this directly rather than sleeping past [threshold]. See
  /// [start] for what this seam cannot prove on its own.
  @visibleForTesting
  void checkNow() => _tick();

  void _tick() {
    final now = _elapsed();
    final last = _lastTick;
    _lastTick = now;
    // No baseline yet (first tick), or the gap happened while backgrounded:
    // neither is a stall. See the class doc for why "backgrounded" is judged
    // at tick time rather than across the whole gap.
    if (last == null || !_foreground) return;

    final gap = now - last;
    if (gap <= threshold) return;

    try {
      onStall(gap);
    } catch (_) {
      // The watchdog must never be the thing that crashes the app it is
      // trying to protect.
    }
  }
}

/// The production default for [UiWatchdog]'s elapsed-time seam: a private,
/// already-running [Stopwatch] wrapped as a zero-argument getter. Kept to a
/// single closure rather than a named class — a monotonic clock is "a
/// stopwatch and a getter," nothing more, and it is never shared across
/// [UiWatchdog] instances because nothing here needs it to be.
Duration Function() _newStopwatchElapsed() {
  final stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsed;
}

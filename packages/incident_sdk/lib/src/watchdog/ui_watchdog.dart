import 'dart:async';

import 'package:flutter/widgets.dart';

/// Called once, on recovery, with how long the UI thread was stalled — never
/// while it's actually blocked. `IncidentCapture.reportStall` has this shape.
typedef StallCallback = void Function(Duration stallDuration);

/// Detects a blocked UI thread (Android's ANR class of failure), which no
/// Flutter error hook reports since nothing throws while the thread is stuck.
///
/// Mechanism: a periodic [Timer] on the same event loop is delayed by
/// exactly how long that loop was blocked, so a heartbeat landing late
/// reveals a stall — measured, not observed, and only reportable afterwards.
///
/// A backgrounded app is not a stalled one: [start] discounts any time spent
/// outside [AppLifecycleState.resumed].
///
/// Known gap: [_tick] judges foreground/background at the moment it runs,
/// not across the whole gap, so a freeze starting just before a backgrounding
/// message arrives is discarded rather than reported. Deliberate — a false
/// positive here is worse than an occasional miss at this exact boundary.
class UiWatchdog extends WidgetsBindingObserver {
  UiWatchdog({
    required this.onStall,
    this.threshold = const Duration(seconds: 5),
    this.heartbeatInterval = const Duration(seconds: 1),
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? _newStopwatchElapsed();

  final StallCallback onStall;

  /// Anything shorter is normal jank. Default tracks Android's own ~5s ANR
  /// window, so this lines up with what the OS itself would flag.
  final Duration threshold;

  /// How often the heartbeat runs; bounds how precisely a stall is measured,
  /// not whether one is detected.
  final Duration heartbeatInterval;

  /// Monotonic time only — [DateTime.now] can jump on NTP correction or a
  /// manual clock change and manufacture or hide a stall that isn't real.
  final Duration Function() _elapsed;

  Timer? _timer;
  Duration? _lastTick;
  bool _foreground = true;

  /// Starts the heartbeat and begins tracking lifecycle changes. Call once,
  /// after the widgets binding exists. Idempotent, so double-init can't spin
  /// up two timers and double-report the same stall.
  ///
  /// One real stall staying one report also relies on [Timer.periodic] never
  /// queuing up missed ticks — a long callback fires again once, not once per
  /// missed interval — a guarantee the unit tests exercise via [checkNow]
  /// rather than a live timer.
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
      // Backgrounded time isn't a stall — restart the baseline here rather
      // than from before backgrounding, or every resume reads as a freeze.
      _lastTick = _elapsed();
    }
    _foreground = resumed;
  }

  /// Test seam: tests advance the injected elapsed-time function and call
  /// this directly instead of sleeping past [threshold].
  @visibleForTesting
  void checkNow() => _tick();

  void _tick() {
    final now = _elapsed();
    final last = _lastTick;
    _lastTick = now;
    // No baseline yet, or the gap happened while backgrounded: neither is a
    // stall (see class doc for why "backgrounded" is judged at tick time).
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

/// Production default for the elapsed-time seam: a running [Stopwatch]
/// wrapped as a getter.
Duration Function() _newStopwatchElapsed() {
  final stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsed;
}

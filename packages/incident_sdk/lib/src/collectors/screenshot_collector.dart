import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../widgets/incident_mask.dart';
import 'collector.dart';

/// Keeps a masked screenshot ready to attach to an incident, captured on
/// demand rather than on a timer — see the task report for why.
///
/// This is opt-in: see [IncidentMask]. A screen inside [boundaryKey] that
/// isn't wrapped is captured as-is.
///
/// - [captureSoon]: call once, right after queuing an incident synchronously
///   without a screenshot (frame capture can't itself be synchronous). Waits
///   up to [captureTimeout]; attach the result to that incident if non-null
///   (`IncidentQueue.amend`).
/// - [didChangeAppLifecycleState]: captures on `inactive`/`paused` as a
///   fallback cache for [collect], for a process that dies without going
///   through a Dart error handler. A hard native crash still gets nothing.
///
/// Wire it up by attaching [boundaryKey] to a [RepaintBoundary] around
/// whatever should be screenshotted (typically the app root):
///
/// ```dart
/// final screenshots = ScreenshotCollector();
/// RepaintBoundary(key: screenshots.boundaryKey, child: child);
/// IncidentSDK.init(..., screenshots: screenshots);
/// ```
///
/// Wrap anything sensitive inside that boundary in [IncidentMask] — nothing
/// here finds sensitive UI on its own.
class ScreenshotCollector extends WidgetsBindingObserver {
  /// Constructing this must not require a live binding: hosts build it as a
  /// top-level `final`, which Dart initialises on first read — at the
  /// `IncidentSDK.init(..., screenshots: screenshots)` argument, before
  /// `init` has had the chance to call `ensureInitialized`. Reaching for
  /// `WidgetsBinding.instance` here crashed release builds on launch.
  ScreenshotCollector({this.maxBytes = 128 * 1024}) {
    WidgetsFlutterBinding.ensureInitialized().addObserver(this);
  }

  /// Dropped, not truncated, if even the smallest downscale exceeds this.
  ///
  /// 128KB of raw PNG, not final payload size: base64 inflates by ~4/3, so
  /// this becomes ~171KB of encoded JSON text — about a third of
  /// `IncidentQueue`'s default 512KB per-incident cap, leaving room for the
  /// rest of the report.
  final int maxBytes;

  /// Bound on a capture attempt, and the hard backstop on masking: whatever
  /// [_armAndRasterize] is doing when this passes, masking clears anyway.
  static const captureTimeout = Duration(milliseconds: 200);

  /// Attach to the `key:` of a [RepaintBoundary] around the capture subtree.
  final GlobalKey boundaryKey = GlobalKey(debugLabel: 'incident_sdk.screenshot');

  static const List<double> _pixelRatios = [1.0, 0.5, 0.25];

  Uint8List? _lastFrame;
  bool _capturing = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.inactive &&
        state != AppLifecycleState.paused) {
      return;
    }
    // Fire-and-forget: must return void and must never throw.
    // ignore: discarded_futures
    _captureOnce().then((bytes) {
      if (bytes != null) _lastFrame = bytes;
    });
  }

  /// See the class doc. Never throws. Falls back to the last
  /// lifecycle-cached frame if a fresh one isn't ready in time — still only
  /// ever handed to the one incident this call is for, via the caller's
  /// `amend`, never attached to incidents automatically.
  Future<Map<String, dynamic>?> captureSoon() async {
    final bytes = await _captureOnce();
    if (bytes != null) {
      _lastFrame = bytes;
      return _entryFor(bytes);
    }
    final cached = _lastFrame;
    return cached == null ? null : _entryFor(cached);
  }

  /// One capture at a time: a crash loop must not pile up a `toImage` + PNG
  /// encode per error, nor hold masking on continuously. Later calls while
  /// one is in flight are dropped, not queued.
  Future<Uint8List?> _captureOnce() async {
    if (_capturing) return null;
    final renderObject = boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) return null;

    _capturing = true;
    incidentMaskingActive.enter();
    try {
      return await _armAndRasterize(renderObject)
          .timeout(captureTimeout, onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      incidentMaskingActive.exit();
      _capturing = false;
    }
  }

  /// A post-frame callback registered while the scheduler is idle fires
  /// only after the next frame's paint, which is what makes it safe to
  /// rasterize once it fires: that paint is guaranteed to see the mask this
  /// call just armed. But if capture starts *during* a frame (this error
  /// was thrown from paint, from semantics, or from another persistent
  /// callback ordered after `RendererBinding`'s own) — `schedulerPhase !=
  /// idle` — the callback instead fires at the end of *that same* frame,
  /// whose paint already ran before the mask was armed. One more full
  /// frame round-trip is burned in that case so the paint actually
  /// rasterized is guaranteed to be the masked one.
  Future<Uint8List?> _armAndRasterize(RenderRepaintBoundary boundary) async {
    final startedMidFrame =
        SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle;
    await _nextPostFrame();
    if (startedMidFrame) await _nextPostFrame();
    return _rasterizeWithinCap(boundary);
  }

  Future<void> _nextPostFrame() {
    final framePainted = Completer<void>();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!framePainted.isCompleted) framePainted.complete();
    });
    // Masking a boundary with no IncidentMask in it wouldn't otherwise
    // request a frame at all.
    SchedulerBinding.instance.scheduleFrame();
    return framePainted.future;
  }

  Future<Uint8List?> _rasterizeWithinCap(RenderRepaintBoundary boundary) async {
    for (final ratio in _pixelRatios) {
      ui.Image? image;
      try {
        image = await boundary.toImage(pixelRatio: ratio);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) continue;
        final bytes = data.buffer.asUint8List();
        if (bytes.length <= maxBytes) return bytes;
      } catch (_) {
        // Try the next, smaller ratio.
      } finally {
        image?.dispose();
      }
    }
    return null;
  }

  Map<String, dynamic> _entryFor(Uint8List bytes) => {
        'format': 'png',
        'bytes': bytes.length,
        'image_base64': base64Encode(bytes),
      };

  /// The cached frame as a context entry — for inspecting or testing this
  /// collector directly. Do not register this as a per-incident collector:
  /// every incident would then carry whatever frame was last cached, not
  /// one that corresponds to that incident; use [captureSoon] + `amend`
  /// instead (see `IncidentSDK.init`'s `screenshots` parameter).
  IncidentCollector get collector => (
        name: 'screenshot',
        collect: () {
          final bytes = _lastFrame;
          if (bytes == null) return const {};
          return _entryFor(bytes);
        },
      );

  /// Stops listening for app lifecycle changes. Not called automatically;
  /// unlike the persistent frame callback this class used to register
  /// (which Flutter cannot ever remove), this one can be undone.
  void dispose() => WidgetsBinding.instance.removeObserver(this);
}

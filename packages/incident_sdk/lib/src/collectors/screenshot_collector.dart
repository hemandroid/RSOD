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
/// demand rather than on a timer.
///
/// Opt-in: wrap sensitive UI inside [boundaryKey] in [IncidentMask] — an
/// unwrapped screen is captured as-is.
///
/// - [captureSoon]: call once right after queuing an incident synchronously
///   (frame capture can't itself be synchronous); attach the result via
///   `IncidentQueue.amend`.
/// - [didChangeAppLifecycleState]: caches a frame on `inactive`/`paused` as
///   a fallback for a process that dies without hitting a Dart error
///   handler. A hard native crash still gets nothing.
///
/// Attach [boundaryKey] to a [RepaintBoundary] around whatever should be
/// screenshotted (typically the app root).
class ScreenshotCollector extends WidgetsBindingObserver {
  /// Must not require a live binding — hosts construct this as a top-level
  /// `final`, before `IncidentSDK.init` can call `ensureInitialized`.
  /// Reaching for `WidgetsBinding.instance` here crashed release builds.
  ScreenshotCollector({this.maxBytes = 128 * 1024}) {
    WidgetsFlutterBinding.ensureInitialized().addObserver(this);
  }

  /// Dropped, not truncated, past this size — ~128KB of raw PNG becomes
  /// ~171KB base64, about a third of `IncidentQueue`'s 512KB cap.
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

  /// Never throws. Falls back to the last lifecycle-cached frame if a
  /// fresh one isn't ready — handed only to the caller's own `amend`.
  Future<Map<String, dynamic>?> captureSoon() async {
    final bytes = await _captureOnce();
    if (bytes != null) {
      _lastFrame = bytes;
      return _entryFor(bytes);
    }
    final cached = _lastFrame;
    return cached == null ? null : _entryFor(cached);
  }

  /// One capture at a time — a crash loop must not pile up encodes or hold
  /// masking on continuously; overlapping calls are dropped, not queued.
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

  /// Captures started mid-frame need one extra frame round-trip so the
  /// mask (armed here) is guaranteed to be in the paint that gets rasterized.
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
    // Without this, a boundary with no IncidentMask wouldn't request a
    // frame at all.
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

  /// The cached frame as a context entry, for inspecting this collector
  /// directly. Do not register as a per-incident collector — every
  /// incident would carry whatever frame was last cached; use
  /// [captureSoon] + `amend` instead.
  IncidentCollector get collector => (
        name: 'screenshot',
        collect: () {
          final bytes = _lastFrame;
          if (bytes == null) return const {};
          return _entryFor(bytes);
        },
      );

  /// Not called automatically. Unlike the persistent callback this class
  /// used to register, this one can be removed.
  void dispose() => WidgetsBinding.instance.removeObserver(this);
}

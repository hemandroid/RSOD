import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Refcounted so overlapping captures (two `ScreenshotCollector`s, a hot
/// reload) can't let one finishing early turn masking off while another is
/// still mid-rasterize — a bare boolean can't express "still needed".
class IncidentMaskGate extends ValueNotifier<bool> {
  IncidentMaskGate() : super(false);

  int _count = 0;

  void enter() {
    _count++;
    value = true;
  }

  void exit() {
    if (_count > 0) _count--;
    if (_count == 0) value = false;
  }
}

/// Public only because Dart privacy is per-file and `ScreenshotCollector`
/// lives elsewhere — not part of this SDK's API. `lib/incident_sdk.dart`
/// must export this file with `show IncidentMask` so this never leaks out.
final IncidentMaskGate incidentMaskingActive = IncidentMaskGate();

/// Marks [child] as sensitive so an incident screenshot never contains it.
///
/// Opt-in: a screen a host app forgot to wrap here is captured as-is —
/// nothing in this package finds sensitive UI on its own.
///
/// Masks inside [RenderObject.paint]: while a capture is in flight, this
/// paints a solid block and never calls the child's paint method, so the
/// real pixels never exist in any buffer an encoder could read — unlike a
/// capture-then-blur approach, which decodes them first. Same technique as
/// `clarity_flutter`'s `ClarityMask`.
///
/// Trade-off: Flutter has one paint pass shared by the live display and any
/// `toImage()` call, so the block also flashes on the user's real screen for
/// as long as the capture takes — up to `ScreenshotCollector.captureTimeout`.
class IncidentMask extends SingleChildRenderObjectWidget {
  const IncidentMask({
    super.key,
    required Widget super.child,
    this.color = const Color(0xFF1A1A1A),
  });

  /// Opaque and mid-tone by default — never a blur (partially reversible)
  /// or fully transparent (hides that something was redacted at all).
  final Color color;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderIncidentMask(color);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderIncidentMask).color = color;
  }
}

class _RenderIncidentMask extends RenderProxyBox {
  _RenderIncidentMask(this._color);

  Color _color;

  set color(Color value) {
    if (_color == value) return;
    _color = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    incidentMaskingActive.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    incidentMaskingActive.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!incidentMaskingActive.value) {
      super.paint(context, offset);
      return;
    }
    // Child is deliberately never painted here — see the class doc.
    context.canvas.drawRect(offset & size, Paint()..color = _color);
  }
}

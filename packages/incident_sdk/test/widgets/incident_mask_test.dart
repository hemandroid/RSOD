import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incident_sdk/src/widgets/incident_mask.dart';

/// Renders [widget] inside a [RepaintBoundary] and returns every pixel as
/// packed 0xAARRGGBB ints, so a test can assert on colors without caring
/// about layout details.
///
/// `toImage`/`toByteData` do real raster-thread work that the fake-async
/// test zone never resolves on its own, so the capture itself has to run
/// inside [WidgetTester.runAsync].
Future<List<int>> _renderPixels(WidgetTester tester, Widget widget) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(key: key, child: widget),
    ),
  );
  await tester.pump();

  return (await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    image.dispose();

    final pixels = <int>[];
    for (var i = 0; i + 3 < bytes.length; i += 4) {
      pixels.add(
        (bytes[i + 3] << 24) |
            (bytes[i] << 16) |
            (bytes[i + 1] << 8) |
            bytes[i + 2],
      );
    }
    return pixels;
  }))!;
}

void main() {
  const sensitive = Color(0xFFFF00FF); // magenta: unmistakable if it leaks.
  const maskColor = Color(0xFF123456);

  tearDown(() {
    // Tests below drive this shared, refcounted gate directly (and a
    // failed expectation can leave it mid-count); drain it rather than
    // just setting `.value`, which would desync the count from the flag
    // and corrupt a later test — see the "refcounted" tests below for why
    // a bare assignment isn't safe any more.
    while (incidentMaskingActive.value) {
      incidentMaskingActive.exit();
    }
  });

  test(
      'stays active until every concurrent capture exits — a bare flag would '
      'let one finishing early unmask a capture that is still running',
      () {
    incidentMaskingActive.enter();
    incidentMaskingActive.enter();
    expect(incidentMaskingActive.value, isTrue);

    incidentMaskingActive.exit(); // one of two overlapping captures finishes...
    expect(incidentMaskingActive.value, isTrue, reason: 'the other is still relying on it');

    incidentMaskingActive.exit();
    expect(incidentMaskingActive.value, isFalse);
  });

  test('exit() never goes negative or requires a balanced enter()', () {
    incidentMaskingActive.exit();
    incidentMaskingActive.exit();
    expect(incidentMaskingActive.value, isFalse);

    incidentMaskingActive.enter();
    expect(incidentMaskingActive.value, isTrue);
    incidentMaskingActive.exit();
    expect(incidentMaskingActive.value, isFalse);
  });

  testWidgets('paints the child normally while masking is inactive',
      (tester) async {
    final pixels = await _renderPixels(
      tester,
      SizedBox(
        width: 8,
        height: 8,
        child: IncidentMask(color: maskColor, child: const ColoredBox(color: sensitive)),
      ),
    );

    expect(pixels, everyElement(sensitive.toARGB32()));
  });

  testWidgets('replaces the child with a solid block while masking is active',
      (tester) async {
    incidentMaskingActive.value = true;

    final pixels = await _renderPixels(
      tester,
      SizedBox(
        width: 8,
        height: 8,
        child: IncidentMask(color: maskColor, child: const ColoredBox(color: sensitive)),
      ),
    );

    // The sensitive content must not appear anywhere in the rasterized
    // output — this is the acceptance test for the whole mechanism: a
    // widget wrapped in IncidentMask does not appear in the captured image.
    expect(pixels, isNot(contains(sensitive.toARGB32())));
    expect(pixels, everyElement(maskColor.toARGB32()));
  });

  testWidgets('masks only the wrapped subtree, not sibling content',
      (tester) async {
    incidentMaskingActive.value = true;

    const visible = Color(0xFF00FF00);
    final pixels = await _renderPixels(
      tester,
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 4, height: 4, child: ColoredBox(color: visible)),
          SizedBox(
            width: 4,
            height: 4,
            child: IncidentMask(color: maskColor, child: const ColoredBox(color: sensitive)),
          ),
        ],
      ),
    );

    expect(pixels, contains(visible.toARGB32()));
    expect(pixels, isNot(contains(sensitive.toARGB32())));
  });

  testWidgets('reverts to painting the child once masking deactivates',
      (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: 8,
            height: 8,
            child: IncidentMask(color: maskColor, child: const ColoredBox(color: sensitive)),
          ),
        ),
      ),
    );

    incidentMaskingActive.value = true;
    await tester.pump();
    final maskedHasSensitive = await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return _hasColor(data!.buffer.asUint8List(), sensitive);
    });
    expect(maskedHasSensitive, isFalse);

    incidentMaskingActive.value = false;
    await tester.pump();
    final revertedHasSensitive = await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return _hasColor(data!.buffer.asUint8List(), sensitive);
    });
    expect(revertedHasSensitive, isTrue);
  });
}

bool _hasColor(Uint8List rgba, Color color) {
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final pixel =
        (rgba[i + 3] << 24) | (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2];
    if (pixel == color.toARGB32()) return true;
  }
  return false;
}

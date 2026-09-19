import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incident_sdk/src/collectors/screenshot_collector.dart';
import 'package:incident_sdk/src/widgets/incident_mask.dart';

/// Delivers the frame [collector] is waiting on and gives its real
/// `toImage()`/PNG-encode work (raster-thread work that only resolves
/// inside [WidgetTester.runAsync] — the normal test zone never drives the
/// callback that completes it, same as every other capture test in this
/// package) a chance to finish, then returns whatever `future` resolves to.
Future<T> _deliverFrameAndAwait<T>(WidgetTester tester, Future<T> future) async {
  await tester.pump();
  return tester.runAsync(() => future).then((v) => v as T);
}

void main() {
  tearDown(() {
    while (incidentMaskingActive.value) {
      incidentMaskingActive.exit();
    }
  });

  testWidgets('collect() is empty until something has actually captured',
      (tester) async {
    final collector = ScreenshotCollector();
    expect(collector.collector.collect(), isEmpty);
  });

  testWidgets('captureSoon() returns null when nothing is wired up',
      (tester) async {
    final collector = ScreenshotCollector();
    expect(await collector.captureSoon(), isNull);
  });

  testWidgets(
      'captureSoon() returns a decodable PNG once the frame it needs arrives',
      (tester) async {
    final collector = ScreenshotCollector();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: collector.boundaryKey,
          child: const SizedBox(
            width: 20,
            height: 20,
            child: ColoredBox(color: Color(0xFF00FF00)),
          ),
        ),
      ),
    );

    final future = collector.captureSoon();
    final context = await _deliverFrameAndAwait(tester, future);

    expect(context, isNotNull);
    expect(context!['format'], 'png');
    expect(context['bytes'], isA<int>());
    expect(context['bytes'], greaterThan(0));

    final decoded = base64Decode(context['image_base64'] as String);
    expect(decoded.length, context['bytes']);
    // PNG file signature — provably an image, not just any base64 blob.
    expect(decoded.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);

    // captureSoon() also refreshes the cache collect() reads synchronously.
    expect(collector.collector.collect(), equals(context));
  });

  testWidgets('a widget wrapped in IncidentMask does not appear in the capture',
      (tester) async {
    final collector = ScreenshotCollector();
    const sensitive = Color(0xFFFF00FF);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: collector.boundaryKey,
          child: const SizedBox(
            width: 20,
            height: 20,
            child: IncidentMask(child: ColoredBox(color: sensitive)),
          ),
        ),
      ),
    );

    final future = collector.captureSoon();
    final context = await _deliverFrameAndAwait(tester, future);

    expect(context, isNotNull);
    final pngBytes = base64Decode(context!['image_base64'] as String);

    // Decode the PNG the collector produced and inspect actual pixels —
    // proving the acceptance criterion at the pixel level, not just
    // trusting that the encoder did the right thing with what it was given.
    final foundMagenta = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(pngBytes);
      final frame = await codec.getNextFrame();
      final raw =
          await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      final rgba = raw!.buffer.asUint8List();
      for (var i = 0; i + 3 < rgba.length; i += 4) {
        if (rgba[i] == 0xFF && rgba[i + 1] == 0x00 && rgba[i + 2] == 0xFF) {
          return true;
        }
      }
      return false;
    });
    expect(foundMagenta, isFalse);
  });

  testWidgets(
      'a second capture while one is already in flight is dropped, not queued',
      (tester) async {
    final collector = ScreenshotCollector();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: collector.boundaryKey,
          child: const SizedBox(
            width: 20,
            height: 20,
            child: ColoredBox(color: Color(0xFF00FF00)),
          ),
        ),
      ),
    );

    final first = collector.captureSoon();
    // `_capturing` is already set by the time the call above yields, so
    // this one sees it and returns null without waiting on anything.
    final second = await collector.captureSoon();
    expect(second, isNull);

    final firstResult = await _deliverFrameAndAwait(tester, first);
    expect(firstResult, isNotNull);
  });

  testWidgets(
      'captureSoon() falls back to the last cached frame when a fresh one '
      'times out', (tester) async {
    final collector = ScreenshotCollector();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: collector.boundaryKey,
          child: const SizedBox(
            width: 20,
            height: 20,
            child: ColoredBox(color: Color(0xFF00FF00)),
          ),
        ),
      ),
    );

    final first = await _deliverFrameAndAwait(tester, collector.captureSoon());
    expect(first, isNotNull);

    // No further pump: this call's own frame wait can never resolve, so it
    // must fall back to the frame already cached by the first call instead
    // of returning null.
    final second = await tester.runAsync(() => collector.captureSoon());
    expect(second, equals(first));
  });

  // No test here forces a *second* real `toImage()` call in one test run:
  // two on the same boundary with no frame between them reliably deadlocks
  // `flutter_tester`'s rasterizer (verified by hand) badly enough that even
  // `Future.timeout` never fires — a harness ceiling, not a production one.

  testWidgets(
      'a capture that never finishes releases the mask instead of leaving '
      'it on forever', (tester) async {
    final collector = ScreenshotCollector();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: collector.boundaryKey,
          child: const SizedBox(
            width: 10,
            height: 10,
            child: ColoredBox(color: Color(0xFF00FF00)),
          ),
        ),
      ),
    );

    // Deliberately never pump another frame after this: the capture can
    // only finish once a post-frame callback fires, so withholding every
    // further frame simulates exactly the "never completes" case a wedged
    // raster thread or a mid-capture backgrounding would cause. The
    // internal bound is a real `Future.timeout` (not the fake test clock),
    // which — like every other real async primitive in this suite — only
    // actually fires inside `runAsync`; this test takes about as long as
    // that timeout in wall time.
    final result = await tester.runAsync(() => collector.captureSoon());

    expect(result, isNull);
    // The whole point: masking must not still be on after the collector
    // gives up on a capture that never arrived.
    expect(incidentMaskingActive.value, isFalse);
  });

  testWidgets(
      'backgrounding the app captures as a fallback for collect()',
      (tester) async {
    final collector = ScreenshotCollector();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: collector.boundaryKey,
          child: const SizedBox(
            width: 20,
            height: 20,
            child: ColoredBox(color: Color(0xFF00FF00)),
          ),
        ),
      ),
    );

    collector.didChangeAppLifecycleState(AppLifecycleState.paused);

    for (var i = 0; i < 10; i++) {
      if (collector.collector.collect().isNotEmpty) break;
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }

    expect(collector.collector.collect(), isNotEmpty);
  });

  testWidgets('resuming (not backgrounding) does not trigger a capture',
      (tester) async {
    final collector = ScreenshotCollector();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: collector.boundaryKey,
          child: const SizedBox(
            width: 20,
            height: 20,
            child: ColoredBox(color: Color(0xFF00FF00)),
          ),
        ),
      ),
    );

    collector.didChangeAppLifecycleState(AppLifecycleState.resumed);

    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }

    expect(collector.collector.collect(), isEmpty);
  });

  testWidgets('dispose() removes the lifecycle observer without throwing',
      (tester) async {
    final collector = ScreenshotCollector();
    expect(WidgetsBinding.instance.removeObserver(collector), isTrue);
    // Already removed by the assertion above; dispose() must still be safe
    // to call (mirrors a host calling it once, normally, during teardown)
    // rather than assuming it is only ever called exactly once anywhere.
    collector.dispose();
  });
}

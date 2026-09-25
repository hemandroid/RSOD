import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsod_demo/main.dart';
import 'package:rsod_demo/store/screens.dart';

void main() {
  setUp(() {
    // The real device is ~411dp wide and every label is multiplied by the
    // app's 1.35x projector text scale. The default 800x600 surface is wider
    // than the phone, so an overflow would pass here and only show on stage.
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(411 * 3, 915 * 3);
    view.devicePixelRatio = 3.0;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    // Every global the app keeps between runs. Leaving `shellTab` out made one
    // test pass alone and fail inside the suite.
    faults
      ..emptyCatalogue = false
      ..duplicateOrders = false
      ..expiredSession = false
      ..paymentApiDown = false
      ..missingRemoteFlag = false;
    shellTab.value = 0;
  });

  testWidgets('happy path reaches the confirmation screen', (tester) async {
    await tester.pumpWidget(const NimbusApp());
    await tester.pumpAndSettle();

    expect(find.textContaining('Featured:'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Add').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Checkout'));
    await tester.pumpAndSettle();
    // The pay button sits below the fold at 411x915 with the 1.35x text
    // scale, so it is not built until scrolled to — as on the real device.
    // `.last`: the shell keeps every tab's ListView mounted, so the first
    // match is the catalogue's, not the pushed checkout route's.
    await tester.drag(find.byType(ListView).last, const Offset(0, -900));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Pay '));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('pay-77'), findsOneWidget);
  });

  testWidgets('an empty catalogue degrades instead of crashing',
      (tester) async {
    faults.emptyCatalogue = true;
    await tester.pumpWidget(const NimbusApp());
    await tester.pumpAndSettle();

    expect(find.text('Nothing featured today'), findsOneWidget);
    expect(find.textContaining('Featured:'), findsNothing);
    // A handled failure must not throw the user onto the crash screen.
    expect(find.text('Something went wrong'), findsNothing);
  });

  testWidgets('a duplicated order id throws on tap', (tester) async {
    faults.duplicateOrders = true;
    await tester.pumpWidget(const NimbusApp());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(NavigationDestination, 'Orders'));
    await tester.pumpAndSettle();

    // Two cards now carry the same id, which is the bug: looking one of them
    // back up with singleWhere throws.
    // No scroll needed: the API inserts the duplicate next to the original
    // so both are on screen together, which is the whole point of the fault.
    expect(find.text('#ord-1001'), findsNWidgets(2));
    await tester.tap(find.text('#ord-1001').first);
    await tester.pump();

    expect(tester.takeException(), isStateError);
  });

  testWidgets('a fault armed after launch still reaches the Orders tab',
      (tester) async {
    // The stage order: the app is already running when the presenter arms the
    // fault in the Chaos panel. The shell's IndexedStack builds every tab at
    // launch, so a list fetched only once at startup would never see it.
    await tester.pumpWidget(const NimbusApp());
    await tester.pumpAndSettle();
    faults.duplicateOrders = true;

    await tester.tap(find.widgetWithText(NavigationDestination, 'Orders'));
    await tester.pumpAndSettle();

    expect(find.text('#ord-1001'), findsNWidgets(2));
  });

  testWidgets('a missing remote flag turns the store into the red screen',
      (tester) async {
    // The stage order: the app is already running when the flag is pulled,
    // and Reload is what pulls the new (broken) response into the build.
    await tester.pumpWidget(const NimbusApp());
    await tester.pumpAndSettle();
    faults.missingRemoteFlag = true;

    await tester.tap(find.text('Reload'));
    // A single pump, not pumpAndSettle: the FutureBuilder rebuilds on the
    // stale data as soon as the new future is assigned, throws right there
    // reading the now-missing flag, and its subscription survives the error
    // to throw the same way again once the new future resolves. One pump
    // catches the first throw and stops before the second.
    await tester.pump();

    // The cast throws while building, so Flutter swaps the store's list for
    // its error box; the tab bar around it keeps working.
    expect(tester.takeException(), isA<TypeError>());
    expect(find.byType(ErrorWidget), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);

    // Let the reload's own future settle so no timer outlives the test; its
    // FutureBuilder throws the same, already-asserted way a second time when
    // it does, which pumpAndSettle would otherwise report as unexpected.
    await tester.pumpAndSettle();
    tester.takeException();
  });

  test('only build-phase errors keep the red screen on show', () {
    FlutterErrorDetails details(String context) => FlutterErrorDetails(
          exception: Exception('x'),
          context: ErrorDescription(context),
        );
    expect(isBuildPhaseError(details('building CatalogueScreen')), isTrue);
    expect(isBuildPhaseError(details('while dispatching a pointer event')),
        isFalse);
    expect(isBuildPhaseError(const FlutterErrorDetails(exception: 'x')),
        isFalse);
  });

  testWidgets('the crash screen tells the user it was reported, with no id',
      (tester) async {
    // The navigation into this screen is wired in main(), which pumpWidget
    // never runs, so this covers the screen's contract rather than the hop.
    await tester.pumpWidget(const MaterialApp(home: FailureScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.textContaining('reported'), findsWidgets);
    // The backend files the ticket asynchronously and never calls back, so
    // this screen must not claim an issue key it cannot know.
    expect(find.textContaining('SCRUM-'), findsNothing);
  });
}

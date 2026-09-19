import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsod_demo/main.dart';

void main() {
  setUp(() {
    faults
      ..emptyCatalogue = false
      ..duplicateOrders = false
      ..expiredSession = false
      ..paymentApiDown = false;
  });

  testWidgets('happy path reaches the confirmation screen', (tester) async {
    await tester.pumpWidget(const NimbusApp());
    await tester.pumpAndSettle();

    expect(find.textContaining('Featured:'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Add').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Checkout'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Pay now'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Payment pay-77'), findsOneWidget);
  });

  testWidgets('an empty catalogue degrades instead of crashing',
      (tester) async {
    faults.emptyCatalogue = true;
    await tester.pumpWidget(const NimbusApp());
    await tester.pumpAndSettle();

    expect(find.text('Nothing featured today'), findsOneWidget);
    expect(find.textContaining('Featured:'), findsNothing);
  });

  testWidgets('a duplicated order id throws on tap', (tester) async {
    faults.duplicateOrders = true;
    await tester.pumpWidget(const NimbusApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.receipt_long));
    await tester.pumpAndSettle();
    // Two cards now carry the same id, which is the bug: looking one of them
    // back up with singleWhere throws.
    expect(find.text('ord-1001'), findsNWidgets(2));
    await tester.tap(find.text('ord-1001').first);
    await tester.pump();

    expect(tester.takeException(), isStateError);
  });
}

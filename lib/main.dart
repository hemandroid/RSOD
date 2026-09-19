import 'package:flutter/material.dart';
import 'package:incident_sdk/incident_sdk.dart';

import 'store/api.dart';
import 'store/screens.dart';

final faults = FaultSwitches();
final api = StoreApi(faults: faults);
final routeHistory = RouteHistoryCollector();
final screenshots = ScreenshotCollector();

void main() {
  IncidentSDK.init(
    // No defaults. A forgotten --dart-define must stop the app dead rather
    // than ship one quietly reporting to nowhere as "demo-token".
    endpoint: const String.fromEnvironment('INCIDENT_ENDPOINT'),
    appToken: const String.fromEnvironment('INCIDENT_APP_TOKEN'),
    // Only ever true for the local sink on a dev machine.
    allowInsecureEndpoint:
        const bool.fromEnvironment('INCIDENT_ALLOW_INSECURE'),
    collectors: [routeHistory.collector],
    screenshots: screenshots,
  );

  runApp(const NimbusApp());
}

class NimbusApp extends StatelessWidget {
  const NimbusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: screenshots.boundaryKey,
      child: MaterialApp(
        title: 'Nimbus Store',
        debugShowCheckedModeBanner: false,
        navigatorObservers: [routeHistory],
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D5AFE)),
          useMaterial3: true,
        ),
        // Projector-legible. textScaler rather than TextTheme.apply: apply()
        // asserts on any style with a null fontSize, and asserts are stripped
        // in release, so it would silently scale nothing on stage.
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: 1.35,
          maxScaleFactor: 1.35,
          child: child!,
        ),
        routes: {
          '/': (_) => const CatalogueScreen(),
          '/cart': (_) => const CartScreen(),
          '/checkout': (_) => const CheckoutScreen(),
          '/orders': (_) => const OrdersScreen(),
          '/settings': (_) => const SettingsScreen(),
          '/confirmation': (_) => const ConfirmationScreen(),
        },
      ),
    );
  }
}

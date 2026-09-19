// Not a test: a compile check that the integration snippet in the library
// doc of `lib/incident_sdk.dart` still names real APIs. Doc comments are not
// analyzed, and that snippet is the first thing an adopter copies.
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:incident_sdk/incident_sdk.dart';

class Home extends StatelessWidget {
  const Home({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void minimal() {
  IncidentSDK.init(
    endpoint: 'https://incidents.example.com/ingest',
    appToken: '...',
  );
  IncidentSDK.log('checkout: applied coupon SAVE10');
}

void full() {
  final routes = RouteHistoryCollector();
  final network = NetworkCollector();
  // ignore: unused_local_variable
  final client = IncidentHttpClient(network, inner: http.Client());
  final screenshots = ScreenshotCollector();

  IncidentSDK.init(
    endpoint: 'https://incidents.example.com/ingest',
    appToken: '...',
    collectors: [routes.collector, network.collector],
    screenshots: screenshots,
  );

  runApp(MaterialApp(
    navigatorObservers: [routes],
    home: RepaintBoundary(key: screenshots.boundaryKey, child: const Home()),
  ));
}

Widget masked(Widget child) => IncidentMask(child: child);

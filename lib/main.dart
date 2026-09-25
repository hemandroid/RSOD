import 'dart:ui';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:incident_sdk/incident_sdk.dart';
import 'package:path_provider/path_provider.dart';

import 'store/api.dart';
import 'store/live_catalogue.dart';
import 'store/screens.dart';
import 'theme.dart';

/// Defaults to false, and must keep doing so: a clone of this repo, a
/// `flutter run` with no defines, and every widget test all have to get the
/// bundled catalogue without touching the network. Only the cloud build
/// sets it — see dart_defines.cloud.json.
const useLiveCatalogue = bool.fromEnvironment('USE_LIVE_CATALOGUE');

final faults = FaultSwitches();
final network = NetworkCollector();
final api = StoreApi(
  faults: faults,
  source: useLiveCatalogue
      ? LiveCatalogue(
          client: IncidentHttpClient(network),
          cacheDir: getApplicationSupportDirectory,
          faults: faults,
        )
      : const MockCatalogue(),
);
final routeHistory = RouteHistoryCollector();
final screenshots = ScreenshotCollector();

/// Which shell tab is showing. A plain notifier rather than a state package:
/// one integer, two writers.
final shellTab = ValueNotifier<int>(0);

final navigatorKey = GlobalKey<NavigatorState>();

/// Fixed rather than following the system setting: the demo must render
/// identically on any device handed to it, including one with accessibility
/// text turned up.
/// A percentage because Dart has no `double.fromEnvironment`.
const _demoTextScalePercent =
    int.fromEnvironment('DEMO_TEXT_SCALE_PERCENT', defaultValue: 100);
const _demoTextScale = _demoTextScalePercent / 100;

void main() {
  IncidentSDK.init(
    // No defaults. A forgotten --dart-define must stop the app dead rather
    // than ship one quietly reporting to nowhere as "demo-token".
    endpoint: const String.fromEnvironment('INCIDENT_ENDPOINT'),
    appToken: const String.fromEnvironment('INCIDENT_APP_TOKEN'),
    // Only ever true for the local sink on a dev machine.
    allowInsecureEndpoint:
        const bool.fromEnvironment('INCIDENT_ALLOW_INSECURE'),
    // Registered in both modes. With the mock source nothing routes through
    // IncidentHttpClient, so it simply contributes an empty trail rather
    // than a collector that exists only on some builds.
    collectors: [routeHistory.collector, network.collector],
    screenshots: screenshots,
  );

  _showFailureScreenOnUnhandledErrors();
  _paintTheRedScreenInRelease();

  runApp(const NimbusApp());
}

/// Chains onto the handlers `IncidentSDK.init` installed rather than replacing
/// them — replacing is how the capture pipeline silently dies. The SDK still
/// files the incident; this only adds the user-facing consequence.
///
/// Deliberately not wired to `IncidentSDK.report`: a handled failure (an empty
/// catalogue degrading to a placeholder) is not a crash and must not throw the
/// user out of the app.
void _showFailureScreenOnUnhandledErrors() {
  final sdkFlutterHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    sdkFlutterHandler?.call(details);
    // A widget that failed to build is already replaced by the error box, and
    // that box is the thing the audience has to see. Covering it with the
    // crash screen would hide the very failure this demo exists to show.
    if (!isBuildPhaseError(details)) _routeToFailure();
  };

  final sdkPlatformHandler = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    final handled = sdkPlatformHandler?.call(error, stack) ?? false;
    _routeToFailure();
    return handled;
  };
}

/// True for an error Flutter raised while building a widget, the only kind
/// that puts an error box on screen. The framework labels those reports
/// `building <element>` (see `ComponentElement.performRebuild`).
bool isBuildPhaseError(FlutterErrorDetails details) =>
    details.context?.toDescription().startsWith('building ') ?? false;

/// A stage decision, not a production one. Release Flutter paints a failed
/// widget as a plain grey box with no text; only debug builds paint the red
/// box with yellow monospace text that people recognise as the red screen.
/// The demo must run a release build, so this restores the debug look using
/// Flutter's own colours and the message it would have printed. The capture
/// behind it is unchanged. A production app would keep the grey box, or show
/// its own friendly fallback.
void _paintTheRedScreenInRelease() {
  RenderErrorBox.backgroundColor = const Color(0xF0900000);
  RenderErrorBox.textStyle = ui.TextStyle(
    color: const Color(0xFFFFFF66),
    fontFamily: 'monospace',
    fontSize: 14,
    fontWeight: FontWeight.bold,
  );
  ErrorWidget.builder = (details) => ErrorWidget.withDetails(
        message: '${details.exception}\n'
            'See also: https://docs.flutter.dev/testing/errors',
        error: details.exception is FlutterError
            ? details.exception as FlutterError
            : null,
      );
}

/// Navigation cannot happen during the build or error phase, so it waits for
/// the frame to finish. Guarded against stacking: one failure often raises
/// several errors, and the user should see one screen, not six.
bool _failureVisible = false;
void _routeToFailure() {
  if (_failureVisible) return;
  _failureVisible = true;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final navigator = navigatorKey.currentState;
    // `?.` alone would short-circuit here with no navigator attached,
    // `whenComplete` would never get chained on, and the flag would stay
    // true forever — the crash screen would never be able to show again.
    if (navigator == null) {
      _failureVisible = false;
      return;
    }
    navigator.pushNamed('/failure').whenComplete(() => _failureVisible = false);
  });
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
        navigatorKey: navigatorKey,
        navigatorObservers: [routeHistory],
        theme: buildNimbusTheme(),
        // Defaults to 1.0 so the app looks like a shipped product; 1.35 made
        // every screen read as though an accessibility setting were stuck on,
        // which undermines the "this is production" premise. Raise it per
        // build if a venue needs it: --dart-define=DEMO_TEXT_SCALE_PERCENT=115
        //
        // textScaler rather than TextTheme.apply: apply() asserts on any style
        // with a null fontSize, and asserts are stripped in release, so it
        // would silently scale nothing on stage.
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: _demoTextScale,
          maxScaleFactor: _demoTextScale,
          child: child!,
        ),
        routes: {
          '/': (_) => const NimbusShell(),
          '/checkout': (_) => const CheckoutScreen(),
          '/settings': (_) => const SettingsScreen(),
          '/confirmation': (_) => const ConfirmationScreen(),
        },
        // A cut, not the default page transition: the default cross-fades the
        // light checkout page into this dark screen, washing the whole display
        // out to grey for a third of a second — read on stage as a flicker.
        // Built here rather than in `routes` so the route keeps its name for
        // the route collector.
        onGenerateRoute: (settings) => settings.name == '/failure'
            ? PageRouteBuilder<void>(
                settings: settings,
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
                pageBuilder: (_, _, _) => const FailureScreen(),
              )
            : null,
      ),
    );
  }
}

/// The four-tab shell. Tab switches do not pass through the navigator, so each
/// one leaves a breadcrumb instead — otherwise the incident's repro steps
/// would skip every move the user made between tabs.
class NimbusShell extends StatefulWidget {
  const NimbusShell({super.key});

  @override
  State<NimbusShell> createState() => _NimbusShellState();
}

class _NimbusShellState extends State<NimbusShell> {
  @override
  void initState() {
    super.initState();
    shellTab.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    shellTab.removeListener(_onTabChanged);
    super.dispose();
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  static const _tabs = ['store', 'cart', 'orders', 'chaos'];

  void _select(int index) {
    IncidentSDK.log('shell: tab -> ${_tabs[index]}');
    shellTab.value = index;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: shellTab.value,
        children: const [
          CatalogueScreen(),
          CartScreen(),
          OrdersScreen(),
          ChaosPanelScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: shellTab.value,
        onDestinationSelected: _select,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.storefront_outlined),
            selectedIcon: Icon(Icons.storefront),
            label: 'Store',
          ),
          NavigationDestination(
            icon: Icon(Icons.shopping_bag_outlined),
            selectedIcon: Icon(Icons.shopping_bag),
            label: 'Cart',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Orders',
          ),
          NavigationDestination(
            icon: Icon(Icons.bolt_outlined),
            selectedIcon: Icon(Icons.bolt),
            label: 'Chaos',
          ),
        ],
      ),
    );
  }
}

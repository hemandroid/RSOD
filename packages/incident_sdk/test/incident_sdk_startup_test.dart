import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incident_sdk/src/incident.dart';
import 'package:incident_sdk/src/incident_sdk_base.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Stands in for the real plugin so the app-support directory resolves to a
/// scratch directory this test owns.
class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// Records every POST the SDK's real transport makes, without a socket.
/// Installed through [HttpOverrides] rather than an injection point on
/// `init`, so these tests exercise the actual `HttpIncidentTransport` the
/// SDK builds from `endpoint` and `appToken` — not a stand-in for it.
class _RecordingHttpClient implements HttpClient {
  _RecordingHttpClient(this.posts);

  final List<_Post> posts;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    final post = _Post(url);
    posts.add(post);
    return _RecordingRequest(post);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Post {
  _Post(this.url);
  final Uri url;
  final Map<String, String> headers = {};
  final StringBuffer body = StringBuffer();
}

class _RecordingRequest implements HttpClientRequest {
  _RecordingRequest(this.post);

  final _Post post;

  @override
  late final HttpHeaders headers = _RecordingHeaders(post.headers);

  @override
  void write(Object? object) => post.body.write(object);

  @override
  Future<HttpClientResponse> close() async => _OkResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingHeaders implements HttpHeaders {
  _RecordingHeaders(this.values);

  final Map<String, String> values;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OkResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      const Stream<List<int>>.empty().listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  // Where init writes before path_provider answers — a fixed path, so the
  // test has to own it rather than create it.
  final startupDir = Directory('${Directory.systemTemp.path}/incidents');

  setUp(() {
    support = Directory.systemTemp.createTempSync('sdk_support');
    if (startupDir.existsSync()) startupDir.deleteSync(recursive: true);
    PathProviderPlatform.instance = _FakePathProvider(support.path);
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    IncidentSDK.resetForTest();
  });

  tearDown(() {
    IncidentSDK.resetForTest();
    if (support.existsSync()) support.deleteSync(recursive: true);
    if (startupDir.existsSync()) startupDir.deleteSync(recursive: true);
  });

  String diskUnder(Directory dir) => String.fromCharCodes(
        dir
            .listSync(recursive: true)
            .whereType<File>()
            .expand((f) => f.readAsBytesSync()),
      );

  test('a crash in the startup window ends up encrypted and not stranded',
      () async {
    IncidentSDK.init(endpoint: 'https://example.test', appToken: 'token');
    IncidentSDK.report(
      StateError('boom'),
      StackTrace.fromString('early-frame'),
    );

    expect(diskUnder(startupDir), contains('early-frame'),
        reason: 'the pre-key policy is to write it, plaintext, not lose it');

    await pumpEventQueue();

    expect(startupDir.existsSync(), isFalse,
        reason: 'plaintext left in the abandoned directory is never swept');
    expect(diskUnder(support), isNot(contains('early-frame')),
        reason: 'the migrated incident must land encrypted');
    expect(IncidentSDK.pendingCount, 1, reason: 'and must still be there');
  });

  test('a zone opened before the swap follows the queue to the durable dir',
      () async {
    IncidentSDK.init(endpoint: 'https://example.test', appToken: 'token');

    // The zone is opened during the startup window, but the error it catches
    // is raised long after the queue has moved.
    IncidentSDK.runGuarded(() {
      Future<void>.delayed(
        const Duration(milliseconds: 20),
        () => throw StateError('late-zone-frame'),
      );
    });

    await pumpEventQueue();
    expect(startupDir.existsSync(), isFalse, reason: 'the queue has moved');

    await Future<void>.delayed(const Duration(milliseconds: 50));
    await pumpEventQueue();

    expect(startupDir.existsSync(), isFalse,
        reason: 'a zone must not resurrect the abandoned temp directory');
    expect(IncidentSDK.pendingCount, 1,
        reason: 'the incident must be in the queue the SDK reports on');
    expect(diskUnder(support), isNot(contains('late-zone-frame')),
        reason: 'and it must be encrypted like any other');
  });

  /// Puts one incident on disk where `init`'s queue will find it on its very
  /// first drain — the uploader starts inside `init`, so anything reported
  /// afterwards would not be attempted until the next round, 30s later.
  void seedPendingIncident() {
    startupDir.createSync(recursive: true);
    File('${startupDir.path}/00000000000001-0000.json').writeAsStringSync(
      Incident(
        id: '00000000000001-0000',
        capturedAt: DateTime.utc(2024),
        source: IncidentSource.manual,
        error: 'seeded',
        stackTrace: '',
        appVersion: '1.0.0',
        commitSha: 'abc',
        platform: 'android',
      ).encode(),
    );
  }

  test('init twice does not start a second uploader', () async {
    seedPendingIncident();
    final posts = <_Post>[];

    await HttpOverrides.runZoned(
      () async {
        IncidentSDK.init(
          endpoint: 'https://example.test/ingest',
          appToken: 'token-123',
          enableUiWatchdog: false,
        );
        IncidentSDK.init(
          endpoint: 'https://example.test/ingest',
          appToken: 'token-123',
          enableUiWatchdog: false,
        );
        await pumpEventQueue();
      },
      createHttpClient: (_) => _RecordingHttpClient(posts),
    );

    expect(posts, hasLength(1),
        reason: 'two upload loops on one queue means every incident is '
            'delivered twice');
    expect(posts.single.url, Uri.parse('https://example.test/ingest'),
        reason: 'the transport is built from the endpoint passed to init');
    expect(posts.single.headers['authorization'], 'Bearer token-123');
    expect(posts.single.body.toString(), contains('seeded'));
    expect(IncidentSDK.pendingCount, 0, reason: 'and then it is cleared');
  });

  test('init twice does not start a second UI watchdog', () async {
    // Threshold zero makes the very first heartbeat (one second in) report,
    // so this needs one real second rather than the five a default
    // threshold would cost. A second watchdog would file its own incident
    // for the same gap.
    IncidentSDK.init(
      endpoint: 'https://example.test/ingest',
      appToken: 'token',
      uiWatchdogThreshold: Duration.zero,
    );
    IncidentSDK.init(
      endpoint: 'https://example.test/ingest',
      appToken: 'token',
      uiWatchdogThreshold: Duration.zero,
    );

    await Future<void>.delayed(const Duration(milliseconds: 1400));
    await pumpEventQueue();

    expect(IncidentSDK.pendingCount, 1,
        reason: 'one heartbeat gap must produce exactly one stall incident');
  });

  test('an endpoint that is not an absolute http URL fails loudly', () {
    expect(
      () => IncidentSDK.init(endpoint: 'example.test', appToken: 'token'),
      throwsArgumentError,
      reason: 'the uploader swallows its own failures, so a typo here would '
          'otherwise only show up as an empty dashboard months later',
    );
    expect(
      () => IncidentSDK.init(endpoint: 'https://example.test', appToken: '  '),
      throwsArgumentError,
    );
  });
}

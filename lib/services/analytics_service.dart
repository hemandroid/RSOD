/// Analytics service interface for logging events
/// This can be easily replaced with Firebase Analytics, Mixpanel, etc.
abstract class AnalyticsService {
  /// Log an error event with details
  Future<void> logErrorEvent({
    required String errorMessage,
    required String stackTrace,
    Map<String, dynamic>? additionalData,
  });

  /// Log a custom event
  Future<void> logEvent({
    required String eventName,
    Map<String, dynamic>? parameters,
  });
}

/// Mock implementation of analytics service
/// Replace this with your actual analytics implementation
class MockAnalyticsService implements AnalyticsService {
  @override
  Future<void> logErrorEvent({
    required String errorMessage,
    required String stackTrace,
    Map<String, dynamic>? additionalData,
  }) async {
    // In production, this would send to your analytics platform
    print('📊 Analytics Event: Error Occurred');
    print('Error: $errorMessage');
    print('Stack Trace: ${stackTrace.substring(0, stackTrace.length > 200 ? 200 : stackTrace.length)}...');
    if (additionalData != null) {
      print('Additional Data: $additionalData');
    }
  }

  @override
  Future<void> logEvent({
    required String eventName,
    Map<String, dynamic>? parameters,
  }) async {
    print('📊 Analytics Event: $eventName');
    if (parameters != null) {
      print('Parameters: $parameters');
    }
  }
}

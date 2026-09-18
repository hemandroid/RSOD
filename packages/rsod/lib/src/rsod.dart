import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'analytics_service.dart';
import 'error_handler_service.dart';

/// Main RSOD class for easy initialization and configuration
class RSOD {
  static ErrorHandlerService? _errorHandler;
  static AnalyticsService? _analyticsService;

  /// Initialize RSOD with optional custom analytics service
  static void initialize({
    AnalyticsService? analyticsService,
    bool showDebugInfo = true,
  }) {
    // Use provided analytics service or default to mock
    _analyticsService = analyticsService ?? MockAnalyticsService();

    // Create error handler
    _errorHandler = ErrorHandlerService(analyticsService: _analyticsService!);

    // Initialize error handling
    _errorHandler!.initialize();

    // Set custom error widget builder
    ErrorWidget.builder = ErrorHandlerService.getErrorWidgetBuilder(kReleaseMode);

    debugPrint('✅ RSOD initialized successfully');
    debugPrint('📊 Analytics: ${analyticsService != null ? "Custom" : "Mock (Default)"}');
    debugPrint('🐛 Debug mode: ${kDebugMode ? "Enabled" : "Disabled"}');
  }

  /// Manually log an error to analytics
  static Future<void> logError({
    required String error,
    required String stackTrace,
    String? context,
  }) async {
    if (_analyticsService != null) {
      await _analyticsService!.logErrorEvent(
        errorMessage: error,
        stackTrace: stackTrace,
        additionalData: {
          'context': context ?? 'Manual log',
          'timestamp': DateTime.now().toIso8601String(),
          'platform': defaultTargetPlatform.toString(),
        },
      );
    } else {
      debugPrint('⚠️  RSOD not initialized. Call RSOD.initialize() first.');
    }
  }

  /// Get the current analytics service
  static AnalyticsService? get analyticsService => _analyticsService;

  /// Check if RSOD is initialized
  static bool get isInitialized => _errorHandler != null;
}

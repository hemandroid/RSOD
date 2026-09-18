import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'analytics_service.dart';

/// Service to handle and configure custom error handling
class ErrorHandlerService {
  final AnalyticsService analyticsService;

  ErrorHandlerService({required this.analyticsService});

  /// Initialize custom error handling
  void initialize() {
    // Handle Flutter framework errors
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      _logError(
        details.exception.toString(),
        details.stack.toString(),
        details.context?.toString(),
      );
    };

    // Handle errors outside of Flutter framework
    PlatformDispatcher.instance.onError = (error, stack) {
      _logError(
        error.toString(),
        stack.toString(),
        null,
      );
      return true;
    };
  }

  /// Log error to analytics
  Future<void> _logError(
    String error,
    String stackTrace,
    String? context,
  ) async {
    try {
      await analyticsService.logErrorEvent(
        errorMessage: error,
        stackTrace: stackTrace,
        additionalData: {
          'context': context ?? 'No context',
          'timestamp': DateTime.now().toIso8601String(),
          'platform': defaultTargetPlatform.toString(),
        },
      );
    } catch (e) {
      // Fail silently to avoid infinite error loops
      debugPrint('Failed to log error to analytics: $e');
    }
  }

  /// Configure custom error widget builder
  static Widget Function(FlutterErrorDetails) getErrorWidgetBuilder(
    bool isReleaseMode,
  ) {
    return (FlutterErrorDetails details) {
      return CustomErrorWidget(
        errorDetails: details,
        isReleaseMode: isReleaseMode,
      );
    };
  }
}

/// Custom error widget displayed when errors occur
class CustomErrorWidget extends StatelessWidget {
  final FlutterErrorDetails errorDetails;
  final bool isReleaseMode;
  final VoidCallback? onClose;

  const CustomErrorWidget({
    super.key,
    required this.errorDetails,
    required this.isReleaseMode,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: isReleaseMode ? Colors.white : Colors.grey[100],
        appBar: AppBar(
          backgroundColor: Colors.pink,
          title: const Text('Error Test Page'),
          actions: [
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: onClose ?? () => Navigator.pop(context),
              tooltip: 'Close',
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Error icon
                  Icon(
                    Icons.error_outline,
                    size: 80,
                    color: isReleaseMode ? Colors.orange : Colors.red,
                  ),
                  const SizedBox(height: 24),

                  // Title
                  Text(
                    isReleaseMode
                        ? 'Oops! Something went wrong'
                        : 'Error Detected',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[800],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),

                  // User-friendly message
                  Text(
                    isReleaseMode
                        ? 'We\'re sorry for the inconvenience. Please try restarting the app.'
                        : 'An error occurred during development',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey[600],
                    ),
                    textAlign: TextAlign.center,
                  ),

                  // Debug information (only in debug mode)
                  if (!isReleaseMode) ...[
                    const SizedBox(height: 32),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.red[50],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red[200]!),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Debug Information:',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.red[900],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            constraints: const BoxConstraints(maxHeight: 200),
                            child: SingleChildScrollView(
                              child: Text(
                                errorDetails.exception.toString(),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  color: Colors.red[800],
                                ),
                              ),
                            ),
                          ),
                          if (errorDetails.stack != null) ...[
                            const SizedBox(height: 8),
                            const Divider(),
                            const SizedBox(height: 8),
                            Text(
                              'Stack Trace:',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.red[900],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              constraints: const BoxConstraints(maxHeight: 150),
                              child: SingleChildScrollView(
                                child: Text(
                                  errorDetails.stack.toString(),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontFamily: 'monospace',
                                    color: Colors.red[700],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 32),

                  // Action buttons
                  if (isReleaseMode)
                    ElevatedButton.icon(
                      onPressed: () {
                        // In a real app, you might want to navigate to home
                        // or implement a restart mechanism
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try Again'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

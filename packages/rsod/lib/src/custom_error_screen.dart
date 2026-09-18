import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A reusable custom error screen widget that can be used anywhere in the app
/// Provides a user-friendly error display with debugging information in debug mode
class CustomErrorScreen extends StatelessWidget {
  final String? title;
  final String? message;
  final String? errorDetails;
  final String? stackTrace;
  final VoidCallback? onRetry;
  final VoidCallback? onGoHome;
  final bool showDebugInfo;

  const CustomErrorScreen({
    super.key,
    this.title,
    this.message,
    this.errorDetails,
    this.stackTrace,
    this.onRetry,
    this.onGoHome,
    this.showDebugInfo = true,
  });

  /// Factory constructor for creating error screen from exception
  factory CustomErrorScreen.fromException({
    required Object exception,
    StackTrace? stackTrace,
    VoidCallback? onRetry,
    VoidCallback? onGoHome,
  }) {
    return CustomErrorScreen(
      errorDetails: exception.toString(),
      stackTrace: stackTrace?.toString(),
      onRetry: onRetry,
      onGoHome: onGoHome,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDebugMode = kDebugMode && showDebugInfo;
    final displayTitle = title ??
        (isDebugMode ? 'Error Detected' : 'Oops! Something went wrong');
    final displayMessage = message ??
        (isDebugMode
            ? 'An error occurred during development'
            : 'We\'re sorry for the inconvenience. Please try again.');

    return Scaffold(
      backgroundColor: isDebugMode ? Colors.grey[100] : Colors.white,
      appBar: isDebugMode
          ? AppBar(
              title: const Text('Error Details'),
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            )
          : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Error icon
                Icon(
                  Icons.error_outline,
                  size: 80,
                  color: isDebugMode ? Colors.red : Colors.orange,
                ),
                const SizedBox(height: 24),

                // Title
                Text(
                  displayTitle,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[800],
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),

                // User-friendly message
                Text(
                  displayMessage,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.grey[600],
                  ),
                  textAlign: TextAlign.center,
                ),

                // Debug information (only in debug mode)
                if (isDebugMode && errorDetails != null) ...[
                  const SizedBox(height: 32),
                  _buildDebugInfoCard(
                    title: 'Error Details',
                    content: errorDetails!,
                    icon: Icons.bug_report,
                  ),
                ],

                if (isDebugMode && stackTrace != null) ...[
                  const SizedBox(height: 16),
                  _buildDebugInfoCard(
                    title: 'Stack Trace',
                    content: stackTrace!,
                    icon: Icons.list,
                    maxHeight: 200,
                  ),
                ],

                const SizedBox(height: 32),

                // Action buttons
                _buildActionButtons(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDebugInfoCard({
    required String title,
    required String content,
    required IconData icon,
    double maxHeight = 150,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: Colors.red[900]),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Colors.red[900],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              child: SelectableText(
                content,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: Colors.red[800],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      alignment: WrapAlignment.center,
      children: [
        if (onRetry != null)
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try Again'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 16,
              ),
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
            ),
          ),
        if (onGoHome != null)
          OutlinedButton.icon(
            onPressed: onGoHome,
            icon: const Icon(Icons.home),
            label: const Text('Go Home'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 16,
              ),
            ),
          ),
        if (onRetry == null && onGoHome == null)
          ElevatedButton.icon(
            onPressed: () {
              // Try to pop if possible
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            },
            icon: const Icon(Icons.arrow_back),
            label: const Text('Go Back'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 16,
              ),
            ),
          ),
      ],
    );
  }
}

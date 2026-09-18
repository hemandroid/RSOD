# RSOD - Red Screen of Death Handler

A Flutter package that replaces the default Flutter Red Screen of Death (RSOD) with a beautiful, user-friendly custom error screen. It includes analytics integration to track errors and provides different displays for debug and release modes.

## Features

✅ **User-Friendly Error Screens** - Replace scary red screens with professional error displays  
✅ **Analytics Integration** - Log errors automatically to your analytics platform  
✅ **Debug & Release Modes** - Show detailed errors in debug, friendly messages in release  
✅ **Customizable** - Easy to customize colors, messages, and behavior  
✅ **Zero Dependencies** - Only depends on Flutter SDK  
✅ **Easy Integration** - Just 3 lines of code to set up  

## Screenshots

| Default RSOD | Custom Error Screen |
|--------------|---------------------|
| ![RSOD](https://via.placeholder.com/300x600/ff0000/ffffff?text=Red+Screen+of+Death) | ![Custom](https://via.placeholder.com/300x600/ffffff/333333?text=Custom+Error+Screen) |

## Installation

### Option 1: Local Package (Development)

Add this to your `pubspec.yaml`:

```yaml
dependencies:
  rsod:
    path: packages/rsod
```

### Option 2: Git Repository

```yaml
dependencies:
  rsod:
    git:
      url: https://github.com/yourusername/rsod.git
      ref: main
```

### Option 3: Pub.dev (Future)

```yaml
dependencies:
  rsod: ^1.0.0
```

Then run:
```bash
flutter pub get
```

## Quick Start

### 1. Basic Setup (3 lines of code)

```dart
import 'package:flutter/material.dart';
import 'package:rsod/rsod.dart';

void main() {
  // Initialize RSOD with default analytics
  RSOD.initialize();

  runApp(const MyApp());
}
```

That's it! Your app now has custom error handling.

### 2. Setup with Custom Analytics

```dart
import 'package:flutter/material.dart';
import 'package:rsod/rsod.dart';

// Create your custom analytics service
class FirebaseAnalyticsService implements AnalyticsService {
  @override
  Future<void> logErrorEvent({
    required String errorMessage,
    required String stackTrace,
    Map<String, dynamic>? additionalData,
  }) async {
    // Send to Firebase Analytics
    await FirebaseAnalytics.instance.logEvent(
      name: 'error_occurred',
      parameters: {
        'error_message': errorMessage,
        'stack_trace': stackTrace,
        ...?additionalData,
      },
    );
  }

  @override
  Future<void> logEvent({
    required String eventName,
    Map<String, dynamic>? parameters,
  }) async {
    await FirebeaseAnalytics.instance.logEvent(
      name: eventName,
      parameters: parameters,
    );
  }
}

void main() {
  // Initialize with your custom analytics
  RSOD.initialize(
    analyticsService: FirebaseAnalyticsService(),
  );

  runApp(const MyApp());
}
```

### 3. Using the Custom Error Screen Widget

You can also use the error screen widget anywhere in your app:

```dart
import 'package:rsod/rsod.dart';

// Navigate to error screen
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (context) => CustomErrorScreen(
      title: 'Connection Failed',
      message: 'Please check your internet connection',
      onRetry: () {
        // Retry logic
        Navigator.pop(context);
      },
      onGoHome: () {
        // Go to home
        Navigator.popUntil(context, (route) => route.isFirst);
      },
    ),
  ),
);

// Or create from exception
try {
  // Some risky operation
} catch (e, stackTrace) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => CustomErrorScreen.fromException(
        exception: e,
        stackTrace: stackTrace,
        onRetry: () => Navigator.pop(context),
      ),
    ),
  );
}
```

## Configuration Options

### Initialize with Options

```dart
RSOD.initialize(
  analyticsService: MyAnalyticsService(),
  showDebugInfo: true,  // Show debug info in debug mode (default: true)
);
```

### Custom Error Widget

```dart
CustomErrorScreen(
  title: 'Custom Title',                    // Optional custom title
  message: 'Custom message',                // Optional custom message
  errorDetails: 'Error details here',       // Optional error details
  stackTrace: 'Stack trace here',           // Optional stack trace
  showDebugInfo: true,                      // Show debug info (default: true)
  onRetry: () {                            // Optional retry callback
    // Retry logic
  },
  onGoHome: () {                           // Optional go home callback
    // Home navigation logic
  },
);
```

## Analytics Integration

### Using the Built-in Mock Analytics (Default)

The package comes with a mock analytics service that prints to console. Perfect for development:

```dart
RSOD.initialize();  // Uses MockAnalyticsService by default
```

Console output:
```
📊 Analytics Event: Error Occurred
Error: Exception: Something went wrong
Stack Trace: #0 MyWidget.build...
Additional Data: {context: ..., timestamp: ..., platform: ...}
```

### Implementing Custom Analytics

Create a class that implements `AnalyticsService`:

```dart
import 'package:rsod/rsod.dart';

class MyAnalyticsService implements AnalyticsService {
  @override
  Future<void> logErrorEvent({
    required String errorMessage,
    required String stackTrace,
    Map<String, dynamic>? additionalData,
  }) async {
    // Send to your analytics platform
    // Examples: Firebase, Mixpanel, Amplitude, Sentry, etc.
  }

  @override
  Future<void> logEvent({
    required String eventName,
    Map<String, dynamic>? parameters,
  }) async {
    // Log custom events
  }
}
```

### Popular Analytics Integrations

#### Firebase Analytics

```dart
class FirebaseAnalyticsService implements AnalyticsService {
  final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  @override
  Future<void> logErrorEvent({
    required String errorMessage,
    required String stackTrace,
    Map<String, dynamic>? additionalData,
  }) async {
    await _analytics.logEvent(
      name: 'app_error',
      parameters: {
        'error_message': errorMessage.substring(0, 100),
        'timestamp': DateTime.now().toIso8601String(),
        ...?additionalData,
      },
    );
  }

  @override
  Future<void> logEvent({
    required String eventName,
    Map<String, dynamic>? parameters,
  }) async {
    await _analytics.logEvent(name: eventName, parameters: parameters);
  }
}
```

#### Sentry

```dart
class SentryAnalyticsService implements AnalyticsService {
  @override
  Future<void> logErrorEvent({
    required String errorMessage,
    required String stackTrace,
    Map<String, dynamic>? additionalData,
  }) async {
    await Sentry.captureException(
      Exception(errorMessage),
      stackTrace: StackTrace.fromString(stackTrace),
    );
  }

  @override
  Future<void> logEvent({
    required String eventName,
    Map<String, dynamic>? parameters,
  }) async {
    Sentry.addBreadcrumb(Breadcrumb(
      message: eventName,
      data: parameters,
    ));
  }
}
```

## Testing Error Handling

### Test Widget Errors

```dart
// Trigger a widget error
Widget build(BuildContext context) {
  return Text(null!); // This will trigger error handling
}
```

### Test Exceptions

```dart
// Throw an exception
throw Exception('Test error');
```

### Visual Testing

The package includes a demo page for testing:

```dart
import 'package:rsod/rsod.dart';

// Navigate to demo page
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (context) => const RSODDemoPage(),
  ),
);
```

## Advanced Usage

### Manual Error Handling

```dart
import 'package:rsod/rsod.dart';

try {
  // Risky operation
} catch (e, stackTrace) {
  // Log error manually
  await RSOD.logError(
    error: e.toString(),
    stackTrace: stackTrace.toString(),
    context: 'Manual error handling',
  );
}
```

### Custom Error Widget Builder

```dart
import 'package:rsod/rsod.dart';

void main() {
  RSOD.initialize(
    analyticsService: MyAnalyticsService(),
  );

  // Override with custom error widget builder
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return MyCustomErrorWidget(details: details);
  };

  runApp(const MyApp());
}
```

## Debug vs Release Mode

### Debug Mode
- Shows detailed error information
- Displays stack traces
- Red/orange color scheme
- Technical details visible
- Helpful for developers

### Release Mode
- Shows user-friendly messages
- Hides technical details
- Professional appearance
- Focus on user experience
- Still logs to analytics

## Best Practices

1. **Initialize Early**: Call `RSOD.initialize()` before `runApp()`
2. **Use Custom Analytics**: Replace mock analytics with your production service
3. **Test Thoroughly**: Use the demo page to test in both debug and release modes
4. **Provide Actions**: Always provide `onRetry` or `onGoHome` callbacks for better UX
5. **Monitor Analytics**: Regularly check error logs to identify and fix issues

## API Reference

### RSOD Class

#### `RSOD.initialize()`
Initialize the error handler with optional analytics service.

Parameters:
- `analyticsService`: Custom analytics service (optional, defaults to MockAnalyticsService)
- `showDebugInfo`: Show debug information in debug mode (optional, default: true)

#### `RSOD.logError()`
Manually log an error to analytics.

Parameters:
- `error`: Error message (required)
- `stackTrace`: Stack trace (required)
- `context`: Additional context (optional)

### CustomErrorScreen Widget

A reusable error screen widget that can be used anywhere in your app.

Properties:
- `title`: Custom title (optional)
- `message`: Custom message (optional)
- `errorDetails`: Error details (optional)
- `stackTrace`: Stack trace (optional)
- `showDebugInfo`: Show debug info (optional, default: true)
- `onRetry`: Retry callback (optional)
- `onGoHome`: Go home callback (optional)

### AnalyticsService Interface

Implement this interface for custom analytics integration.

Methods:
- `logErrorEvent()`: Log error events
- `logEvent()`: Log custom events

## Examples

See the [example](example/) directory for complete working examples.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Support

- 📧 Email: support@example.com
- 🐛 Issues: [GitHub Issues](https://github.com/yourusername/rsod/issues)
- 💬 Discussions: [GitHub Discussions](https://github.com/yourusername/rsod/discussions)

## Credits

Created with ❤️ by [Your Name]

## Related Packages

- [flutter_error_boundary](https://pub.dev/packages/flutter_error_boundary)
- [catcher](https://pub.dev/packages/catcher)
- [sentry_flutter](https://pub.dev/packages/sentry_flutter)

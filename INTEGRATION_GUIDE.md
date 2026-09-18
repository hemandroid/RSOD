# RSOD Package - Integration & Testing Guide

## 📦 Package Overview

**RSOD** (Red Screen of Death Handler) is a reusable Flutter package that replaces the default Flutter Red Screen of Death with a beautiful, user-friendly custom error screen. It includes built-in analytics integration to track errors in production.

---

## 🎯 What You Get

✅ **User-Friendly Error Screens** - Replace scary red screens with professional error displays  
✅ **Analytics Integration** - Automatically log errors to track issues  
✅ **Debug & Release Modes** - Different displays for development vs production  
✅ **Reusable Components** - Use error screens anywhere in your app  
✅ **Zero External Dependencies** - Only depends on Flutter SDK  
✅ **Easy Integration** - Just 3 lines of code to set up  

---

## 📁 Package Structure

```
packages/rsod/
├── lib/
│   ├── rsod.dart                          # Main export file
│   └── src/
│       ├── analytics_service.dart          # Analytics interface
│       ├── custom_error_screen.dart        # Reusable error screen widget
│       ├── error_handler_service.dart      # Error handling logic
│       ├── rsod.dart                       # Main RSOD class
│       └── demo/
│           └── rsod_demo_page.dart         # Demo/testing page
├── pubspec.yaml                            # Package configuration
├── README.md                               # Package documentation
├── CHANGELOG.md                            # Version history
├── LICENSE                                 # MIT License
└── analysis_options.yaml                   # Lint rules
```

---

## 🚀 Step-by-Step Integration Guide

### Step 1: Add Package Dependency

Add the RSOD package to your project's `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  rsod:
    path: packages/rsod  # Local package path
```

**Alternative methods:**

```yaml
# From Git repository (future)
dependencies:
  rsod:
    git:
      url: https://github.com/yourusername/rsod.git
      
# From pub.dev (future)
dependencies:
  rsod: ^1.0.0
```

### Step 2: Install Dependencies

Run the following command in your terminal:

```bash
cd /Users/c21866e/Mobile_Projects/flutter_demos/rsod_demo
flutter pub get
```

### Step 3: Basic Integration (Quickest Way)

Update your `main.dart` file:

```dart
import 'package:flutter/material.dart';
import 'package:rsod/rsod.dart';  // Import RSOD package

void main() {
  // Initialize RSOD (just 1 line!)
  RSOD.initialize();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'My App',
      home: const HomePage(),
    );
  }
}
```

**That's it!** Your app now has custom error handling with analytics.

---

## 🔧 Advanced Integration

### Custom Analytics Integration

If you want to use your own analytics service (Firebase, Mixpanel, Sentry, etc.):

```dart
import 'package:flutter/material.dart';
import 'package:rsod/rsod.dart';
import 'package:firebase_analytics/firebase_analytics.dart';

// Step 1: Create custom analytics service
class MyFirebaseAnalytics implements AnalyticsService {
  final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  @override
  Future<void> logErrorEvent({
    required String errorMessage,
    required String stackTrace,
    Map<String, dynamic>? additionalData,
  }) async {
    await _analytics.logEvent(
      name: 'app_error_occurred',
      parameters: {
        'error_message': errorMessage.substring(0, 100),
        'timestamp': DateTime.now().toIso8601String(),
        'platform': additionalData?['platform'] ?? 'unknown',
      },
    );
  }

  @override
  Future<void> logEvent({
    required String eventName,
    Map<String, dynamic>? parameters,
  }) async {
    await _analytics.logEvent(
      name: eventName,
      parameters: parameters,
    );
  }
}

void main() {
  // Step 2: Initialize with your custom analytics
  RSOD.initialize(
    analyticsService: MyFirebaseAnalytics(),
  );

  runApp(const MyApp());
}
```

---

## 🧪 Testing the Integration

### Method 1: Use the Built-in Demo Page

The package includes a demo page for testing both scenarios:

```dart
import 'package:flutter/material.dart';
import 'package:rsod/rsod.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My App')),
      body: Center(
        child: ElevatedButton(
          onPressed: () {
            // Open the RSOD demo page
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const RSODDemoPage(),
              ),
            );
          },
          child: const Text('Open RSOD Demo'),
        ),
      ),
    );
  }
}
```

The demo page allows you to:
- ✅ Toggle between custom handler and default RSOD
- ✅ Trigger test errors
- ✅ See console logs in real-time
- ✅ Compare both error handling approaches

### Method 2: Trigger Test Errors Manually

```dart
// Test 1: Widget Error
ElevatedButton(
  onPressed: () {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Text(null!), // This will trigger error
      ),
    );
  },
  child: const Text('Test Widget Error'),
),

// Test 2: Throw Exception
ElevatedButton(
  onPressed: () {
    throw Exception('Test error for RSOD!');
  },
  child: const Text('Test Exception'),
),
```

### Method 3: Use CustomErrorScreen Widget Directly

```dart
// Navigate to custom error screen
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (context) => CustomErrorScreen(
      title: 'Test Error',
      message: 'This is a test error screen',
      errorDetails: 'Some error details here',
      onRetry: () => Navigator.pop(context),
      onGoHome: () => Navigator.popUntil(context, (route) => route.isFirst),
    ),
  ),
);

// Or create from exception
try {
  // risky operation
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

---

## 📊 Verifying Analytics Logging

### Default Mock Analytics (Development)

When using the default mock analytics, you'll see console output like this:

```
✅ RSOD initialized successfully
📊 Analytics: Mock (Default)
🐛 Debug mode: Enabled

[When error occurs:]
📊 Analytics Event: Error Occurred
Error: Exception: Test error
Stack Trace: #0 _MyWidgetState.build...
Additional Data: {context: No context, timestamp: 2026-02-03T10:30:45.123Z, platform: TargetPlatform.iOS}
```

### Custom Analytics (Production)

With your custom analytics service, errors will be sent to your configured platform:

- **Firebase Analytics**: Check your Firebase console under Events
- **Sentry**: Check your Sentry dashboard for captured exceptions
- **Mixpanel**: Check your Mixpanel events stream
- **Custom**: Verify in your analytics platform

---

## 🎨 Customization Examples

### Example 1: Custom Error Messages

```dart
CustomErrorScreen(
  title: 'Network Error',
  message: 'Unable to connect to the server. Please check your internet connection.',
  onRetry: () {
    // Retry network request
    Navigator.pop(context);
  },
  onGoHome: () {
    Navigator.popUntil(context, (route) => route.isFirst);
  },
)
```

### Example 2: Hide Debug Info in Production

```dart
CustomErrorScreen(
  title: 'Something went wrong',
  message: 'We\'re working on fixing this issue.',
  errorDetails: error.toString(),
  showDebugInfo: false,  // Hide debug info even in debug mode
  onRetry: () => Navigator.pop(context),
)
```

### Example 3: Error Boundary Pattern

```dart
class ErrorBoundary extends StatefulWidget {
  final Widget child;
  
  const ErrorBoundary({super.key, required this.child});

  @override
  State<ErrorBoundary> createState() => _ErrorBoundaryState();
}

class _ErrorBoundaryState extends State<ErrorBoundary> {
  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
```

---

## 🔍 Testing Checklist

Use this checklist to verify your integration:

### Basic Integration
- [ ] Package added to `pubspec.yaml`
- [ ] `flutter pub get` executed successfully
- [ ] `RSOD.initialize()` called in `main()`
- [ ] App runs without errors

### Error Handling
- [ ] Custom error screen shows instead of red screen
- [ ] Error screen is user-friendly in release mode
- [ ] Debug info shows in debug mode
- [ ] Action buttons work correctly

### Analytics
- [ ] Analytics service is initialized
- [ ] Errors are logged to analytics
- [ ] Console shows analytics events (if using mock)
- [ ] Custom analytics receives events (if configured)

### Different Scenarios
- [ ] Widget errors are handled correctly
- [ ] Thrown exceptions are caught
- [ ] CustomErrorScreen widget works standalone
- [ ] Demo page functions properly

### Platform Testing
- [ ] Tested on iOS (or simulator)
- [ ] Tested on Android (or emulator)
- [ ] Tested on Web (if applicable)
- [ ] Tested on macOS/Windows (if applicable)

### Build Modes
- [ ] Debug mode shows detailed error info
- [ ] Release mode shows user-friendly messages
- [ ] Profile mode works correctly

---

## 📝 Real-World Usage Examples

### Example 1: API Error Handling

```dart
Future<void> fetchData() async {
  try {
    final response = await http.get(Uri.parse('https://api.example.com/data'));
    if (response.statusCode != 200) {
      throw Exception('API returned ${response.statusCode}');
    }
    // Process data
  } catch (e, stackTrace) {
    // Show custom error screen
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CustomErrorScreen.fromException(
          exception: e,
          stackTrace: stackTrace,
          onRetry: () {
            Navigator.pop(context);
            fetchData(); // Retry
          },
        ),
      ),
    );
  }
}
```

### Example 2: Form Validation with Error Screen

```dart
void submitForm() async {
  try {
    if (!_formKey.currentState!.validate()) {
      throw Exception('Form validation failed');
    }
    
    await saveData();
    
  } catch (e, stackTrace) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CustomErrorScreen(
          title: 'Submission Failed',
          message: 'Unable to submit the form. Please try again.',
          errorDetails: e.toString(),
          onRetry: () {
            Navigator.pop(context);
            submitForm();
          },
        ),
      ),
    );
  }
}
```

### Example 3: Global Error Handler

```dart
void main() {
  // Initialize RSOD
  RSOD.initialize(
    analyticsService: MyAnalyticsService(),
  );

  // Catch errors in zones
  runZonedGuarded(
    () => runApp(const MyApp()),
    (error, stackTrace) {
      RSOD.logError(
        error: error.toString(),
        stackTrace: stackTrace.toString(),
        context: 'Uncaught zone error',
      );
    },
  );
}
```

---

## 🐛 Troubleshooting

### Issue: Package not found

**Solution:**
```bash
# Make sure you're in the right directory
cd /Users/c21866e/Mobile_Projects/flutter_demos/rsod_demo

# Clean and get dependencies
flutter clean
flutter pub get
```

### Issue: Errors still show red screen

**Solution:**
- Make sure `RSOD.initialize()` is called BEFORE `runApp()`
- Check console for initialization messages
- Verify package is imported: `import 'package:rsod/rsod.dart';`

### Issue: Analytics not logging

**Solution:**
- Check if custom analytics service is properly implemented
- Use mock analytics to test: `RSOD.initialize()` (without parameters)
- Check console output for analytics events
- Verify your analytics service methods are async

### Issue: Demo page not found

**Solution:**
```dart
import 'package:rsod/rsod.dart'; // Make sure this import exists

// Then use:
const RSODDemoPage()
```

---

## 📚 API Quick Reference

### RSOD Class

```dart
// Initialize with default mock analytics
RSOD.initialize();

// Initialize with custom analytics
RSOD.initialize(analyticsService: MyAnalyticsService());

// Manually log an error
await RSOD.logError(
  error: 'Error message',
  stackTrace: 'Stack trace',
  context: 'Additional context',
);

// Check if initialized
bool initialized = RSOD.isInitialized;

// Get analytics service
AnalyticsService? service = RSOD.analyticsService;
```

### CustomErrorScreen Widget

```dart
// Basic usage
CustomErrorScreen(
  title: 'Error Title',
  message: 'Error message',
  onRetry: () {},
  onGoHome: () {},
)

// From exception
CustomErrorScreen.fromException(
  exception: exception,
  stackTrace: stackTrace,
  onRetry: () {},
)

// Full options
CustomErrorScreen(
  title: 'Custom Title',
  message: 'Custom message',
  errorDetails: 'Error details',
  stackTrace: 'Stack trace',
  showDebugInfo: true,
  onRetry: () {},
  onGoHome: () {},
)
```

### AnalyticsService Interface

```dart
class MyAnalytics implements AnalyticsService {
  @override
  Future<void> logErrorEvent({
    required String errorMessage,
    required String stackTrace,
    Map<String, dynamic>? additionalData,
  }) async {
    // Your implementation
  }

  @override
  Future<void> logEvent({
    required String eventName,
    Map<String, dynamic>? parameters,
  }) async {
    // Your implementation
  }
}
```

---

## 🎓 Learning Path

### Beginner
1. Follow Step 1-3 of basic integration
2. Run the app and test with demo page
3. Observe console logs

### Intermediate
1. Create custom analytics service
2. Integrate with Firebase/Sentry
3. Use CustomErrorScreen in try-catch blocks

### Advanced
1. Implement error boundaries
2. Create custom error widgets extending the package
3. Add error recovery strategies
4. Implement offline error queuing

---

## ✅ Success Criteria

Your integration is successful when:

1. ✅ App shows custom error screen instead of red screen
2. ✅ Analytics logs errors automatically
3. ✅ Debug mode shows detailed information
4. ✅ Release mode shows user-friendly messages
5. ✅ Error screens have working action buttons
6. ✅ Console shows RSOD initialization message
7. ✅ Demo page works and demonstrates both scenarios

---

## 📞 Support & Resources

- **Package Location:** `/packages/rsod/`
- **Main Documentation:** `packages/rsod/README.md`
- **Demo Page:** Use `RSODDemoPage()` widget
- **Example Integration:** Check your `main.dart` file

---

## 🎉 Next Steps

After successful integration:

1. **Test thoroughly** using the demo page
2. **Configure analytics** with your production service
3. **Customize error messages** for your brand
4. **Test in release mode** to see production behavior
5. **Monitor analytics** to track real errors
6. **Add error recovery** logic where needed

---

## 📄 License

MIT License - See `packages/rsod/LICENSE` for details

---

**Created with ❤️ for Flutter Developers**

For questions or issues, check the troubleshooting section or review the package documentation in `packages/rsod/README.md`.

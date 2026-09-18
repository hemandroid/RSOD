# Custom Error Handling Demo - RSOD (Red Screen of Death) Replacement

This Flutter application demonstrates a comprehensive custom error handling solution that replaces the default "Red Screen of Death" with user-friendly error screens.

## 🎯 Features

### 1. **Custom Error Screen Widget**
- ✅ User-friendly error display in release mode
- ✅ Detailed debugging information in debug mode
- ✅ Reusable component that can be used anywhere in the app
- ✅ Configurable with custom messages and actions

### 2. **Global Error Handler Service**
- ✅ Catches all Flutter framework errors
- ✅ Catches errors outside of Flutter framework
- ✅ Integrates with analytics service
- ✅ Automatically logs errors with context

### 3. **Analytics Integration**
- ✅ Mock analytics service (easily replaceable)
- ✅ Automatic error event logging
- ✅ Includes error details, stack trace, and context
- ✅ Ready for Firebase, Mixpanel, or custom analytics

## 📁 Project Structure

```
lib/
├── main.dart                           # Main app with error handling setup
├── services/
│   ├── analytics_service.dart          # Analytics interface and mock implementation
│   └── error_handler_service.dart      # Global error handling service
└── widgets/
    └── custom_error_screen.dart        # Reusable error screen widget
```

## 🚀 Getting Started

### Prerequisites
- Flutter SDK (3.10.1 or higher)
- Dart SDK
- Android Studio / Xcode (for mobile testing)
- Chrome (for web testing)

### Installation

1. **Clone or navigate to the project**
   ```bash
   cd rsod_demo
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Run the app**
   ```bash
   # For Android Emulator
   flutter run -d emulator-5554
   
   # For iOS Simulator
   flutter run -d iPhone
   
   # For Chrome (fastest for testing)
   flutter run -d chrome
   
   # For macOS Desktop
   flutter run -d macos
   ```

## 🧪 Testing the Error Handling

The app includes two test buttons on the home screen:

### 1. **Show Custom Error Screen** (Orange button)
- Opens the custom error screen as a navigation page
- Demonstrates how to use the error screen widget manually
- Shows "Retry" and "Go Home" action buttons
- Perfect for testing navigation and user actions

### 2. **Trigger Test Error** (Red button)
- Throws a real exception to test the global error handler
- Demonstrates automatic error catching
- Shows how the error widget replaces the red screen
- Analytics event is logged automatically

## 📚 Usage Guide

### Basic Setup (Already implemented in main.dart)

```dart
void main() {
  // Initialize analytics service
  final analyticsService = MockAnalyticsService();
  
  // Initialize error handler
  final errorHandler = ErrorHandlerService(analyticsService: analyticsService);
  errorHandler.initialize();

  // Set custom error widget builder
  ErrorWidget.builder = ErrorHandlerService.getErrorWidgetBuilder(kReleaseMode);

  runApp(const MyApp());
}
```

### Using Custom Error Screen in Your Code

```dart
// Navigate to error screen
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (context) => CustomErrorScreen(
      title: 'Custom Error Title',
      message: 'A user-friendly error message',
      errorDetails: 'Technical details for debugging',
      stackTrace: stackTrace.toString(),
      onRetry: () {
        // Handle retry action
        Navigator.pop(context);
      },
      onGoHome: () {
        // Navigate to home
        Navigator.popUntil(context, (route) => route.isFirst);
      },
    ),
  ),
);
```

### Using Factory Constructor

```dart
try {
  // Your code that might throw
} catch (error, stackTrace) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => CustomErrorScreen.fromException(
        exception: error,
        stackTrace: stackTrace,
        onRetry: () => _retryOperation(),
      ),
    ),
  );
}
```

## 🔧 Customization

### Replace Mock Analytics with Real Implementation

Replace `MockAnalyticsService` with your actual analytics service:

```dart
// For Firebase Analytics
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
        'error_message': errorMessage,
        'stack_trace': stackTrace.substring(0, 100), // Firebase has limits
        ...?additionalData,
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
```

Then update main.dart:
```dart
final analyticsService = FirebaseAnalyticsService(); // Instead of MockAnalyticsService()
```

### Customize Error Screen Appearance

Edit `lib/widgets/custom_error_screen.dart` to change:
- Colors and themes
- Icons and images
- Button styles
- Layout and spacing
- Error message formatting

### Customize Error Behavior

Edit `lib/services/error_handler_service.dart` to:
- Change error logging behavior
- Add custom error processing
- Modify error reporting
- Add error recovery logic

## 🎨 Design Decisions

### Release Mode vs Debug Mode

**Release Mode:**
- Shows simplified, user-friendly error messages
- Hides technical details and stack traces
- Uses softer colors (orange instead of red)
- Focuses on user actions (Try Again)

**Debug Mode:**
- Shows complete error details
- Includes full stack traces
- Uses developer-friendly formatting
- Allows error copying and inspection

### Error Handling Strategy

1. **Global Error Catching:**
   - `FlutterError.onError` for Flutter framework errors
   - `PlatformDispatcher.instance.onError` for async errors

2. **Custom Error Widget:**
   - Replaces default ErrorWidget
   - Provides consistent error UI
   - Works across all widgets

3. **Manual Error Screens:**
   - Use `CustomErrorScreen` for expected errors
   - Better user experience for known error states
   - Full control over navigation and actions

## 📊 Analytics Events

The system automatically logs the following events:

### Error Event
```json
{
  "event": "app_error",
  "error_message": "Exception: Something went wrong",
  "stack_trace": "Full stack trace...",
  "context": "Error context",
  "timestamp": "2026-02-03T10:30:00.000Z",
  "platform": "android"
}
```

## ✅ Acceptance Criteria Fulfillment

1. ✅ **Custom error screen created** - `CustomErrorScreen` widget
2. ✅ **Visually appealing and user-friendly** - Clean design, appropriate colors
3. ✅ **Includes debugging information** - Full details in debug mode
4. ✅ **Analytics event logging** - Automatic logging via `ErrorHandlerService`
5. ✅ **Reusable component** - Can be used anywhere in the app
6. ✅ **Release mode protection** - No red screen in production

## 🧪 Testing Checklist

- [ ] Run app in debug mode
- [ ] Click "Trigger Test Error" button
- [ ] Verify custom error widget appears (not red screen)
- [ ] Check console for analytics event log
- [ ] Click "Show Custom Error Screen" button
- [ ] Test "Retry" button functionality
- [ ] Test "Go Home" button functionality
- [ ] Build and run in release mode: `flutter run --release`
- [ ] Trigger error in release mode
- [ ] Verify user-friendly message (no technical details)

## 🔍 Troubleshooting

### App doesn't run
```bash
flutter clean
flutter pub get
flutter run
```

### Error screen not showing
- Check that error handler is initialized in main()
- Verify ErrorWidget.builder is set
- Check that error is being thrown correctly

### Analytics not logging
- Check console output for print statements
- Verify analytics service is initialized
- Check that analytics service is passed to error handler

## 📝 License

This is a demo project for educational purposes.

## 🤝 Contributing

This is a demo project. Feel free to use and modify as needed for your projects.

---

**Built with Flutter 💙**

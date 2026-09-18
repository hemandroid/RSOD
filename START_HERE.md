# 🎯 RSOD Package - Start Here

## 📦 What's This?

This repository contains the **RSOD** (Red Screen of Death Handler) package - a reusable Flutter package that replaces Flutter's default red error screens with beautiful, user-friendly error displays.

---

## 🚀 Quick Start (30 seconds)

### 1. Add Package
```yaml
# pubspec.yaml
dependencies:
  rsod:
    path: packages/rsod
```

### 2. Initialize
```dart
import 'package:rsod/rsod.dart';

void main() {
  RSOD.initialize();
  runApp(const MyApp());
}
```

### 3. Test It
```dart
// Trigger test error
throw Exception('Test error');
```

**Done!** You now have professional error handling. ✅

---

## 📚 Documentation

Choose your path based on what you need:

### 🎯 I want to get started FAST
**→ Read:** [`VISUAL_QUICK_REFERENCE.md`](VISUAL_QUICK_REFERENCE.md)
- Visual guide with diagrams
- Quick setup steps
- Key concepts at a glance

### 📖 I want complete integration steps
**→ Read:** [`INTEGRATION_GUIDE.md`](INTEGRATION_GUIDE.md)
- Step-by-step instructions
- Testing methods
- Custom analytics setup
- Troubleshooting
- Real-world examples

### 📦 I want to understand the package
**→ Read:** [`PACKAGE_SUMMARY.md`](PACKAGE_SUMMARY.md)
- Package overview
- Feature list
- Structure explanation
- Verification checklist

### 💻 I want working code to copy
**→ See:** [`packages/rsod/example/main_example.dart`](packages/rsod/example/main_example.dart)
- Complete working example
- Ready to copy and paste
- All features demonstrated

### 📘 I want detailed package docs
**→ Read:** [`packages/rsod/README.md`](packages/rsod/README.md)
- Full package documentation
- API reference
- Advanced features
- Analytics integrations

---

## 🎨 What You Get

### Before (Default Flutter)
❌ Red screen with technical errors  
❌ Scary for users  
❌ No analytics tracking  
❌ Unprofessional appearance  

### After (RSOD Package)
✅ User-friendly error screens  
✅ Professional design  
✅ Automatic analytics logging  
✅ Debug/release mode support  
✅ Customizable messages  
✅ Action buttons (Retry, Home)  

---

## 📂 Package Location

```
packages/rsod/
```

The package is self-contained and ready to use or publish.

---

## 🧪 Testing

### Option 1: Use the Demo Page
```dart
import 'package:rsod/rsod.dart';

Navigator.push(context, MaterialPageRoute(
  builder: (_) => const RSODDemoPage(),
));
```

The demo page lets you:
- ✅ Toggle between default RSOD and custom handler
- ✅ Trigger test errors
- ✅ See real-time console logs
- ✅ Compare both approaches side-by-side

### Option 2: Use the Example App
```bash
# Copy the example to main.dart
cp packages/rsod/example/main_example.dart lib/main.dart

# Run it
flutter run
```

---

## 📊 Features

### 🎨 User-Friendly Error Screens
- Clean, professional design
- Customizable titles and messages
- Works in any part of your app

### 📈 Analytics Integration
- Automatic error logging
- Platform-agnostic interface
- Works with Firebase, Sentry, Mixpanel, etc.
- Mock analytics included for testing

### 🐛 Debug Mode Support
- Detailed error information
- Stack traces visible
- Easy troubleshooting

### 🚀 Release Mode Optimization
- User-friendly messages only
- No technical details shown
- Professional appearance

### 🧩 Reusable Components
- Use `CustomErrorScreen` anywhere
- Navigate to error screens manually
- Create from exceptions easily

### 🧪 Testing Tools
- Interactive demo page included
- Toggle between modes
- Real-time console logging

---

## 🔧 Package Structure

```
packages/rsod/
├── lib/
│   ├── rsod.dart                     → Import this file
│   └── src/
│       ├── rsod.dart                 → Main RSOD class
│       ├── analytics_service.dart    → Analytics interface
│       ├── custom_error_screen.dart  → Error screen widget
│       ├── error_handler_service.dart → Core logic
│       └── demo/
│           └── rsod_demo_page.dart   → Testing demo
├── example/
│   └── main_example.dart             → Working example
├── pubspec.yaml                      → Package config
├── README.md                         → Package docs
├── QUICK_START.md                    → Quick guide
├── CHANGELOG.md                      → Version history
└── LICENSE                           → MIT License
```

---

## 💡 Usage Examples

### Basic Setup
```dart
void main() {
  RSOD.initialize();
  runApp(const MyApp());
}
```

### With Custom Analytics
```dart
void main() {
  RSOD.initialize(
    analyticsService: MyFirebaseAnalytics(),
  );
  runApp(const MyApp());
}
```

### Manual Error Screen
```dart
try {
  await riskyOperation();
} catch (e, stack) {
  Navigator.push(context, MaterialPageRoute(
    builder: (_) => CustomErrorScreen.fromException(
      exception: e,
      stackTrace: stack,
      onRetry: () => retry(),
    ),
  ));
}
```

### Custom Messages
```dart
CustomErrorScreen(
  title: 'Network Error',
  message: 'Please check your connection',
  onRetry: () => reconnect(),
  onGoHome: () => goHome(),
)
```

---

## 📋 Quick Reference

| Task | Command/Code |
|------|-------------|
| Install | Add to `pubspec.yaml` and run `flutter pub get` |
| Import | `import 'package:rsod/rsod.dart';` |
| Initialize | `RSOD.initialize();` |
| Test | Use `RSODDemoPage()` widget |
| Custom Screen | Use `CustomErrorScreen()` widget |
| Log Error | `RSOD.logError(...)` |

---

## ✅ Success Criteria

Your integration is successful when:

1. ✅ Console shows: "✅ RSOD initialized successfully"
2. ✅ Errors show custom screen (not red screen)
3. ✅ Demo page works and shows both modes
4. ✅ Analytics logs appear in console
5. ✅ Action buttons work correctly

---

## 🎓 Recommended Reading Order

1. **First:** [`VISUAL_QUICK_REFERENCE.md`](VISUAL_QUICK_REFERENCE.md) - Get an overview
2. **Then:** [`INTEGRATION_GUIDE.md`](INTEGRATION_GUIDE.md) - Follow the steps
3. **Finally:** [`packages/rsod/README.md`](packages/rsod/README.md) - Deep dive into features

---

## 🐛 Troubleshooting

### Package not found?
```bash
flutter clean && flutter pub get
```

### Still showing red screen?
- Make sure `RSOD.initialize()` is called BEFORE `runApp()`
- Check the import: `import 'package:rsod/rsod.dart';`

### Analytics not logging?
- Check console (mock analytics prints logs)
- Verify custom analytics implements `AnalyticsService`

**Full troubleshooting guide:** See [`INTEGRATION_GUIDE.md`](INTEGRATION_GUIDE.md)

---

## 📞 Need Help?

1. **Quick answers:** See [`VISUAL_QUICK_REFERENCE.md`](VISUAL_QUICK_REFERENCE.md)
2. **Detailed help:** See [`INTEGRATION_GUIDE.md`](INTEGRATION_GUIDE.md)
3. **Package docs:** See [`packages/rsod/README.md`](packages/rsod/README.md)
4. **Working example:** See [`packages/rsod/example/main_example.dart`](packages/rsod/example/main_example.dart)

---

## 🎉 Ready to Use!

The RSOD package is production-ready and fully documented. Choose your starting point above and get going!

**Most popular starting point:** [`INTEGRATION_GUIDE.md`](INTEGRATION_GUIDE.md)

---

## 📄 License

MIT License - See [`packages/rsod/LICENSE`](packages/rsod/LICENSE)

---

**Package Version:** 1.0.0  
**Status:** ✅ Production Ready  
**Created:** February 3, 2026

---

### Quick Navigation

- 📖 [Integration Guide](INTEGRATION_GUIDE.md) - Complete setup instructions
- 🎯 [Visual Quick Reference](VISUAL_QUICK_REFERENCE.md) - Quick visual guide  
- 📦 [Package Summary](PACKAGE_SUMMARY.md) - Overview and checklist
- 📘 [Package README](packages/rsod/README.md) - Full documentation
- 💻 [Example Code](packages/rsod/example/main_example.dart) - Working example
- 🚀 [Quick Start](packages/rsod/QUICK_START.md) - Fastest setup

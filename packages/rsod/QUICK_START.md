# RSOD Package - Quick Start Example

## 🚀 Fastest Way to Get Started

### 1. Add to pubspec.yaml

```yaml
dependencies:
  rsod:
    path: packages/rsod
```

### 2. Update main.dart

```dart
import 'package:flutter/material.dart';
import 'package:rsod/rsod.dart';

void main() {
  RSOD.initialize();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RSOD Demo',
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RSOD Package Demo')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'RSOD Package is Active!',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 40),
            
            // Open demo page
            ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const RSODDemoPage(),
                  ),
                );
              },
              icon: const Icon(Icons.science),
              label: const Text('Open Demo Page'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
            
            const SizedBox(height: 20),
            
            // Test error directly
            ElevatedButton.icon(
              onPressed: () {
                throw Exception('Test Error - RSOD will handle this!');
              },
              icon: const Icon(Icons.bug_report),
              label: const Text('Trigger Test Error'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
            
            const SizedBox(height: 20),
            
            // Show custom error screen
            OutlinedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => CustomErrorScreen(
                      title: 'Custom Error Example',
                      message: 'This is a custom error screen you can use anywhere!',
                      onRetry: () => Navigator.pop(context),
                      onGoHome: () => Navigator.popUntil(context, (route) => route.isFirst),
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.error_outline),
              label: const Text('Show Custom Error Screen'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

### 3. Run the app

```bash
flutter pub get
flutter run
```

## ✅ Expected Results

When you run the app:
1. Console shows: "✅ RSOD initialized successfully"
2. Click "Trigger Test Error" - you'll see a custom error screen instead of red screen
3. Click "Open Demo Page" - you can test and compare both error handling modes
4. Click "Show Custom Error Screen" - see how to use the widget anywhere

## 📊 Console Output

You should see:
```
✅ RSOD initialized successfully
📊 Analytics: Mock (Default)
🐛 Debug mode: Enabled
```

When an error occurs:
```
📊 Analytics Event: Error Occurred
Error: Exception: Test Error - RSOD will handle this!
Stack Trace: #0 HomePage.build...
Additional Data: {context: No context, timestamp: 2026-02-03T10:30:45.123Z, platform: ...}
```

## 🎯 Next Steps

- Read the full [Integration Guide](../INTEGRATION_GUIDE.md)
- Check the [README](README.md) for advanced features
- Integrate your own analytics service
- Customize error messages
- Test in release mode

That's it! You now have professional error handling in your Flutter app! 🎉

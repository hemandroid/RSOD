import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../rsod.dart';

/// Demo page to test and compare RSOD with custom error handling
class RSODDemoPage extends StatefulWidget {
  const RSODDemoPage({super.key});

  @override
  State<RSODDemoPage> createState() => _RSODDemoPageState();
}

class _RSODDemoPageState extends State<RSODDemoPage> {
  bool _useCustomErrorHandler = true;
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _addLog('🚀 RSOD Demo initialized');
    _addLog('📍 Current mode: ${kDebugMode ? "DEBUG" : "RELEASE"}');
    _addLog('✅ Custom error handler is ENABLED by default');
  }

  void _addLog(String message) {
    setState(() {
      _logs.add('[${DateTime.now().toString().split(' ')[1].substring(0, 8)}] $message');
    });
    debugPrint(message);
  }

  void _clearLogs() {
    setState(() {
      _logs.clear();
    });
    _addLog('🧹 Logs cleared');
  }

  void _toggleErrorHandler() {
    setState(() {
      _useCustomErrorHandler = !_useCustomErrorHandler;
    });

    if (_useCustomErrorHandler) {
      // Re-enable custom error handler
      RSOD.initialize();
      _addLog('✅ Custom Error Handler ENABLED');
      _addLog('   ↳ Will show user-friendly error screen');
      _addLog('   ↳ Analytics logging is active');
    } else {
      // Disable custom error handler to show default RSOD
      ErrorWidget.builder = (FlutterErrorDetails details) {
        return ErrorWidget(details.exception);
      };
      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
      };
      _addLog('❌ Custom Error Handler DISABLED');
      _addLog('   ↳ Will show Flutter RED SCREEN OF DEATH');
      _addLog('   ↳ No analytics logging');
    }
  }

  void _triggerWidgetError() {
    _addLog('⚠️  Triggering widget render error...');
    _addLog('   ↳ This will cause an error in the widget tree');

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _ErrorTriggerWidget(
          onClose: () {
            Navigator.pop(context);
            _addLog('✨ Error widget dismissed');
          },
        ),
      ),
    );
  }

  void _triggerThrowError() {
    _addLog('💥 Throwing exception...');
    _addLog('   ↳ This simulates an unexpected error');

    // Trigger error after a brief delay so the log can be seen
    Future.delayed(const Duration(milliseconds: 100), () {
      throw Exception('Demo Error: This is a test exception to demonstrate error handling!');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RSOD Demo - Error Comparison'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Status Banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: _useCustomErrorHandler ? Colors.green[100] : Colors.red[100],
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _useCustomErrorHandler ? Icons.check_circle : Icons.warning,
                      color: _useCustomErrorHandler ? Colors.green[800] : Colors.red[800],
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _useCustomErrorHandler
                          ? 'Custom Error Handler: ACTIVE'
                          : 'Default RSOD: ACTIVE',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: _useCustomErrorHandler ? Colors.green[900] : Colors.red[900],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _useCustomErrorHandler
                      ? 'Errors will show user-friendly screen with analytics'
                      : 'Errors will show Flutter red screen of death',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[700],
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),

          // Control Panel
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Control Panel',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),

                // Toggle Switch
                SwitchListTile(
                  title: const Text('Use Custom Error Handler'),
                  subtitle: Text(
                    _useCustomErrorHandler
                        ? 'Shows user-friendly error screen'
                        : 'Shows default Flutter RSOD',
                  ),
                  value: _useCustomErrorHandler,
                  onChanged: (value) => _toggleErrorHandler(),
                  activeThumbColor: Colors.green,
                ),

                const Divider(height: 32),

                const Text(
                  'Trigger Test Errors',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),

                // Test Button 1
                ElevatedButton.icon(
                  onPressed: _triggerWidgetError,
                  icon: const Icon(Icons.bug_report),
                  label: const Text('Trigger Widget Error'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),

                const SizedBox(height: 12),

                // Test Button 2
                OutlinedButton.icon(
                  onPressed: _triggerThrowError,
                  icon: const Icon(Icons.error_outline),
                  label: const Text('Throw Exception'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red, width: 2),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ],
            ),
          ),

          // Logs Section
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[700]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(12),
                        topRight: Radius.circular(12),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.terminal, color: Colors.white, size: 16),
                            SizedBox(width: 8),
                            Text(
                              'Console Logs',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.clear_all, color: Colors.white, size: 20),
                          onPressed: _clearLogs,
                          tooltip: 'Clear logs',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            _logs[index],
                            style: TextStyle(
                              fontFamily: 'Courier',
                              fontSize: 12,
                              color: _logs[index].contains('✅')
                                  ? Colors.green[300]
                                  : _logs[index].contains('❌')
                                      ? Colors.red[300]
                                      : _logs[index].contains('⚠️') || _logs[index].contains('💥')
                                          ? Colors.orange[300]
                                          : Colors.white,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Widget that intentionally causes an error
class _ErrorTriggerWidget extends StatelessWidget {
  final VoidCallback? onClose;

  const _ErrorTriggerWidget({this.onClose});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('This widget will cause an error below:'),
            const SizedBox(height: 20),
            // This will cause an error by throwing exception
            Text(
              _getErrorText()!,
              style: const TextStyle(fontSize: 18),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: onClose ?? () => Navigator.pop(context),
        icon: const Icon(Icons.close),
        label: const Text('Dismiss Error'),
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
      ),
    );
  }

  String? _getErrorText() {
    // Intentionally throw error
    throw Exception('Widget rendering error: Null value encountered!');
  }
}

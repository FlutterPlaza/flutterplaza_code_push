import 'package:flutter/material.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Wrap your app with CodePushOverlay for automatic OTA updates.
  // It checks for patches on startup, periodically, and on app resume.
  // When a patch is downloaded, a banner prompts the user to restart.
  runApp(
    CodePushOverlay(
      config: CodePushConfig(
        serverUrl: 'https://your-server.com',
        appId: 'your-app-id',
        releaseVersion: '1.0.0+1',
        checkInterval: const Duration(hours: 4),
      ),
      showDebugBar: true, // Set to false in production.
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: const CodePushDemo(),
    );
  }
}

class CodePushDemo extends StatefulWidget {
  const CodePushDemo({super.key});

  @override
  State<CodePushDemo> createState() => _CodePushDemoState();
}

class _CodePushDemoState extends State<CodePushDemo> {
  String _status = 'Idle';
  bool _isPatched = false;
  PatchInfo? _currentPatch;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final patched = await CodePush.isPatched;
    final patch = await CodePush.currentPatch;
    setState(() {
      _isPatched = patched;
      _currentPatch = patch;
    });
  }

  Future<void> _manualCheck() async {
    setState(() => _status = 'Checking for updates...');
    try {
      final installed = await CodePush.checkAndInstall(
        serverUrl: 'https://your-server.com',
        appId: 'your-app-id',
        releaseVersion: '1.0.0+1',
        onUpdateReady: () {
          setState(() => _status = 'Patch installed! Restart to apply.');
        },
      );
      if (!installed) {
        setState(() => _status = 'No update available.');
      }
      await _loadStatus();
    } on CodePushException catch (e) {
      setState(() => _status = 'Error: ${e.message}');
    }
  }

  Future<void> _rollback() async {
    setState(() => _status = 'Rolling back...');
    try {
      await CodePush.rollback();
      setState(() => _status = 'Rolled back. Restart to revert.');
      await _loadStatus();
    } on CodePushException catch (e) {
      setState(() => _status = 'Rollback failed: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Code Push Demo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Status card.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Status',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text('Patched: $_isPatched'),
                  if (_currentPatch != null) ...[
                    Text('Active patch: ${_currentPatch!.version}'),
                    Text('Installed: ${_currentPatch!.installedAt}'),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Update status.
          Text(_status, textAlign: TextAlign.center),

          const SizedBox(height: 16),

          // Manual update check.
          ElevatedButton(
            onPressed: _manualCheck,
            child: const Text('Check for Updates'),
          ),
          const SizedBox(height: 8),

          // Rollback (only enabled when patched).
          OutlinedButton(
            onPressed: _isPatched ? _rollback : null,
            child: const Text('Rollback'),
          ),

          const SizedBox(height: 24),

          // CodePushPatchBuilder: reacts to live module results.
          // Use this to patch specific parts of your UI without a full restart.
          CodePushPatchBuilder(
            patchKey: 'banner',
            builder: (context, patchData, child) {
              if (patchData == null) return child!;
              return Card(
                color: Colors.green.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(patchData),
                ),
              );
            },
            child: const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('Default banner content'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

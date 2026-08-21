import 'package:flutter/material.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Wrap your app with CodePushOverlay for automatic OTA updates.
  // It checks for patches on startup, periodically, and on app resume.
  // On Android/desktop a downloaded patch shows a restart banner; on iOS
  // the first patch is applied live (no banner) and the banner appears
  // only when a different patch arrives while one is already loaded.
  // The overlay runs its own check cycle, so the manual button below can
  // race it (see _manualCheck).
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
        // `false` does NOT necessarily mean "no update" — it also means
        // "another check is already running" (the overlay's own cycle wins
        // the single-flight guard). Don't report it as "no update".
        setState(() => _status = 'No new patch installed '
            '(no update, or a check is already in progress).');
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
                  // NOTE: isPatched / currentPatch read the engine channel,
                  // which is disabled on iOS — they show false/null there even
                  // while a patch is active. On iOS use CodePush.moduleResult /
                  // CodePush.status (see the CodePushPatchBuilder below) as the
                  // active-patch signal.
                  Text('Patched (Android/desktop): $_isPatched'),
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

          // Rollback is always available — it is failure-soft (_rollback
          // surfaces "No active patch to roll back" when there's nothing to
          // undo). Do NOT gate on _isPatched: that reads false on iOS even
          // while a patch is active, which would wrongly disable rollback on
          // iOS, where it works (Dart-side file removal).
          OutlinedButton(
            onPressed: _rollback,
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

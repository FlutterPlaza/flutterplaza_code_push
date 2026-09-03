import 'package:flutter/material.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Wrap your app with CodePushOverlay for automatic OTA updates.
  // It checks for patches on startup, periodically, and on app resume.
  // On Android/desktop a downloaded patch shows a restart banner; on iOS
  // the first patch is applied live (no banner) and the banner appears only
  // when a different patch arrives while one is already loaded, or when a
  // resident patch is re-offered after a rollback reverted the content.
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
    // Guard every setState that follows an await: the overlay re-keys the
    // app subtree when a patch activates (see the build-method note below),
    // which disposes this State mid-await — a late setState would then
    // throw in debug builds.
    if (!mounted) return;
    setState(() {
      _isPatched = patched;
      _currentPatch = patch;
    });
  }

  Future<void> _manualCheck() async {
    setState(() => _status = 'Checking for updates...');
    try {
      // The callback, not the return value, is the restart-prompt
      // signal: it can fire even when checkAndInstall returns false
      // (a patch installed earlier this session still awaiting its
      // restart). Track it so the false-branch below doesn't clobber
      // the prompt it just showed.
      var updateAnnounced = false;
      final installed = await CodePush.checkAndInstall(
        serverUrl: 'https://your-server.com',
        appId: 'your-app-id',
        releaseVersion: '1.0.0+1',
        onUpdateReady: () {
          updateAnnounced = true;
          // checkAndInstall invokes this synchronously, before the await
          // below resumes — but the overlay can re-key this subtree while
          // the check is in flight, so the callback can land on a
          // disposed State. Hence the mounted guard.
          if (!mounted) return;
          setState(() => _status = 'Patch installed! Restart to apply.');
        },
      );
      if (!mounted) return;
      if (!installed) {
        // `false` is not just "no update" — checkAndInstall also returns false
        // for "a check is already running", a download failure, a hash
        // mismatch, a server error, and more. The specific reason is in
        // CodePush.status, which checkAndInstall writes before every false
        // return, so surface that rather than guessing. Note that
        // onUpdateReady above can fire even on a false return: when a
        // patch installed earlier this session still awaits a restart,
        // the first callback-passing call is told so ('Patch already
        // installed' in status) — treat the callback, not the return
        // value, as the "show the restart prompt" signal.
        if (!updateAnnounced) {
          setState(() =>
              _status = 'No new patch installed: ${CodePush.status.value}');
        }
      }
      await _loadStatus();
    } on CodePushException catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Error: ${e.message}');
    }
  }

  Future<void> _rollback() async {
    setState(() => _status = 'Rolling back...');
    try {
      await CodePush.rollback();
      if (!mounted) return;
      setState(() => _status = 'Rolled back. Restart to revert.');
      await _loadStatus();
    } on CodePushException catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Rollback failed: ${e.message}');
    } catch (e) {
      // The iOS Dart-side rollback deletes the resident patch file, which can
      // throw a FileSystemException (not a CodePushException) if it is already
      // gone or unreadable — catch it so the button never leaves an exception
      // unhandled.
      if (!mounted) return;
      setState(() => _status = 'Rollback failed: $e');
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
                  // while a patch is active. On iOS, listen to
                  // CodePush.moduleResult (a level) with a
                  // ValueListenableBuilder<Object?> as the active-patch signal
                  // — NOT CodePush.status: 'Patch active' is a fleeting edge,
                  // and the overlay re-keys the app subtree when a patch loads,
                  // so any latch a widget here holds is discarded (this State
                  // itself is recreated on iOS load). The CodePushPatchBuilder
                  // below is a convenience for string patches keyed by prefix,
                  // not the auto-parsed Map moduleResult holds.
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

          // The iOS patch signal the note above prescribes: moduleResult is a
          // level, so a ValueListenableBuilder over it reflects the resident
          // patch even after the overlay re-keys this subtree. It holds the raw
          // payload (a Map/List on iOS, or a string), so render defensively.
          ValueListenableBuilder<Object?>(
            valueListenable: CodePush.moduleResult,
            builder: (context, result, _) {
              if (result == null) return const Text('No live patch payload');
              return Text('Live patch payload: $result');
            },
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

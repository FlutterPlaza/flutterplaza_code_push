import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
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
  double _progress = 0;
  bool _isPatched = false;
  String _releaseVersion = '';
  PatchInfo? _currentPatch;
  int _patchCount = 0;
  Timer? _periodicTimer;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _periodicTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    try {
      final results = await Future.wait([
        CodePush.isPatched,
        CodePush.releaseVersion,
        CodePush.currentPatch,
        CodePush.patchCount,
      ]);
      setState(() {
        _isPatched = results[0] as bool;
        _releaseVersion = results[1] as String;
        _currentPatch = results[2] as PatchInfo?;
        _patchCount = results[3] as int;
      });
    } on CodePushException {
      // Engine not available — running without code push.
    }
  }

  Future<void> _checkAndApply() async {
    setState(() {
      _status = 'Checking for updates...';
      _progress = 0;
    });

    try {
      final update = await CodePush.checkForUpdate();
      if (!update.isUpdateAvailable) {
        setState(() => _status = 'No update available');
        return;
      }

      setState(
        () => _status = 'Downloading ${update.patchVersion} '
            '(${_formatBytes(update.downloadSize)})...',
      );

      await CodePush.downloadAndApply(
        onProgress: (progress) {
          setState(() => _progress = progress);
        },
      );

      setState(() => _status = 'Patch applied! Restart to activate.');
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

  Future<void> _cleanup() async {
    try {
      final removed = await CodePush.cleanupOldPatches();
      setState(() => _status = 'Cleaned up $removed old patch(es).');
      await _loadStatus();
    } on CodePushException catch (e) {
      setState(() => _status = 'Cleanup failed: ${e.message}');
    }
  }

  void _togglePeriodicCheck() {
    if (_periodicTimer != null && _periodicTimer!.isActive) {
      _periodicTimer!.cancel();
      setState(() => _status = 'Periodic checking stopped.');
      return;
    }

    _periodicTimer = CodePush.checkForUpdatePeriodically(
      interval: const Duration(hours: 4),
      onUpdateAvailable: (update) {
        setState(() {
          _status = 'Update found: ${update.patchVersion}';
        });
      },
    );
    setState(() => _status = 'Checking every 4 hours...');
  }

  String _formatBytes(int? bytes) {
    if (bytes == null) return 'unknown size';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
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
                  Text('Release: $_releaseVersion'),
                  Text('Patched: $_isPatched'),
                  Text('Patches on device: $_patchCount'),
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
          if (_progress > 0 && _progress < 1)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(value: _progress),
            ),

          const SizedBox(height: 16),

          // Actions.
          ElevatedButton(
            onPressed: _checkAndApply,
            child: const Text('Check for Updates'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _isPatched ? _rollback : null,
            child: const Text('Rollback'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _cleanup,
            child: const Text('Cleanup Old Patches'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _togglePeriodicCheck,
            child: Text(
              _periodicTimer?.isActive == true
                  ? 'Stop Periodic Check'
                  : 'Start Periodic Check (4h)',
            ),
          ),
        ],
      ),
    );
  }
}

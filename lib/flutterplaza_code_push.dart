/// Over-the-air code push updates for Flutter apps.
///
/// This package provides the runtime API for FlutterPlaza Code Push.
/// It communicates with the custom code-push engine via platform channels
/// to check for updates, download and apply patches, and roll back.
///
/// ## Quick start
///
/// Wrap your app with [CodePushOverlay]:
///
/// ```dart
/// runApp(
///   CodePushOverlay(
///     config: CodePushConfig(
///       serverUrl: 'https://api.codepush.flutterplaza.com',
///       appId: 'your-app-id',
///       releaseVersion: '1.0.0+1',
///     ),
///     child: MyApp(),
///   ),
/// );
/// ```
library;

export 'src/code_push.dart'
    show CodePush, CodePushConfig, CodePushOverlay, CodePushPatchBuilder;
export 'src/models.dart';

#import <Foundation/Foundation.h>

// ============================================================================
// FlutterplazaCodePushBootCleanup
// ============================================================================
//
// Deletes a stale `patch.vmcode` file from the app's Documents directory
// BEFORE the Flutter engine has a chance to load it during isolate
// initialization.
//
// Why this lives in +load and not in a Flutter plugin register method:
//
//   The code-push-enabled Flutter engine loads `patch.vmcode` as the
//   isolate's snapshot data/instructions during isolate creation —
//   before `Dart_InvokeMain`, before `main()`, before any Dart user
//   code has a chance to run. If the patch on disk was written by a
//   previous install of the app and is incompatible with the current
//   engine/baseline, the Dart VM aborts with a SIGABRT inside
//   `DN_Internal_loadDynamicModule` and the process is killed before
//   a single line of Dart executes.
//
//   Earlier versions of this SDK (0.1.3, 0.1.4, 0.1.5) tried to clean
//   up the stale patch from Dart inside `CodePush.init()`. That could
//   never work: `init()` runs inside `main()`, and `main()` never runs
//   in the crash scenario. The fix has to happen in native code that
//   runs BEFORE the Flutter engine is instantiated.
//
//   `+load` on an Objective-C class inside a pod that the app links
//   against runs during dyld image loading — the earliest hook
//   available to Flutter plugins. It fires before `main()` in the
//   ObjC entry point, before `UIApplicationMain`, before
//   `FlutterAppDelegate.application:didFinishLaunchingWithOptions:`,
//   before any Flutter engine code, before any Dart code.
//
// The cleanup is a no-op in all normal cases:
//
//   - No `patch.vmcode` on disk → no-op.
//   - Patch is newer than the app binary (steady state: user installed
//     the patch a few minutes ago and is relaunching the app) → no-op.
//   - App binary is newer than the patch (upgrade scenario: store
//     update replaced the `.app` bundle but preserved the Documents
//     directory) → delete the patch and its siblings.
//
// Bundle freshness is measured as the MAX of two mtimes:
//
//   - `Runner.app/Runner` (the Objective-C / Swift shell)
//   - `Runner.app/Frameworks/App.framework/App` (the Dart AOT snapshot)
//
// Either file missing is tolerated. If both are missing, cleanup is
// skipped and the engine's three-strike auto-rollback takes over as
// a last-resort safety net.
// ============================================================================

@interface FlutterplazaCodePushBootCleanup : NSObject
@end

@implementation FlutterplazaCodePushBootCleanup

+ (void)load {
  // Wrap the entire cleanup in an autorelease pool. +load runs very
  // early in the app lifecycle when the main autorelease pool may not
  // yet exist, so any allocations here need their own pool.
  @autoreleasepool {
    [self fcpCleanupStalePatchBeforeEngineBoots];
  }
}

+ (void)fcpCleanupStalePatchBeforeEngineBoots {
  NSFileManager *fileManager = [NSFileManager defaultManager];

  // ── Locate the patch file ────────────────────────────────────────
  //
  // The custom Flutter engine hardcodes the patch directory as
  // `<NSDocumentDirectory>/code_push_patches` (see
  // FlutterDartProject.mm in the engine fork). Replicate that path
  // here without any method-channel round-trip.
  NSArray<NSString *> *documentPaths = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES);
  if (documentPaths.count == 0) {
    return;
  }
  NSString *patchDirPath =
      [documentPaths.firstObject stringByAppendingPathComponent:@"code_push_patches"];
  NSString *patchPath =
      [patchDirPath stringByAppendingPathComponent:@"patch.vmcode"];

  if (![fileManager fileExistsAtPath:patchPath]) {
    return; // Nothing to clean up.
  }

  NSError *patchAttrError = nil;
  NSDictionary *patchAttrs =
      [fileManager attributesOfItemAtPath:patchPath error:&patchAttrError];
  if (patchAttrError || !patchAttrs) {
    return;
  }
  NSDate *patchMtime = [patchAttrs fileModificationDate];
  if (!patchMtime) {
    return;
  }

  // ── Compute bundle freshness (max of Runner + App.framework/App) ──
  //
  // iOS replaces the entire `.app` bundle when a user installs or
  // upgrades the app, so both the Runner shell and the App.framework
  // AOT snapshot get fresh mtimes. We take the MAX of the two so the
  // comparison works in every Flutter incremental-build cadence:
  //
  //   * Native-only rebuild → Runner advances
  //   * Dart-only rebuild   → App.framework/App advances
  //   * Full build          → both advance
  //
  // Either file missing is tolerated — we just use the other.
  NSBundle *mainBundle = [NSBundle mainBundle];
  NSDate *bundleMtime = nil;

  NSString *runnerPath = [mainBundle executablePath];
  if (runnerPath) {
    NSDictionary *runnerAttrs =
        [fileManager attributesOfItemAtPath:runnerPath error:nil];
    NSDate *runnerMtime = [runnerAttrs fileModificationDate];
    if (runnerMtime) {
      bundleMtime = runnerMtime;
    }
  }

  NSString *appFrameworkPath =
      [[mainBundle bundlePath] stringByAppendingPathComponent:
                                   @"Frameworks/App.framework/App"];
  NSDictionary *appFrameworkAttrs =
      [fileManager attributesOfItemAtPath:appFrameworkPath error:nil];
  NSDate *appFrameworkMtime = [appFrameworkAttrs fileModificationDate];
  if (appFrameworkMtime) {
    if (!bundleMtime ||
        [appFrameworkMtime compare:bundleMtime] == NSOrderedDescending) {
      bundleMtime = appFrameworkMtime;
    }
  }

  if (!bundleMtime) {
    // Can't determine bundle freshness — fall through to the engine's
    // three-strike auto-rollback safety net.
    return;
  }

  // ── Decide and delete ─────────────────────────────────────────────
  //
  // Bundle newer than patch → patch was written by a previous install
  // and may be incompatible with the current engine/baseline. Delete
  // it and its siblings so the engine boots clean. The SDK will
  // re-download a compatible patch on the next `checkAndInstall`.
  if ([bundleMtime compare:patchMtime] == NSOrderedDescending) {
    NSError *delError = nil;
    if ([fileManager removeItemAtPath:patchPath error:&delError]) {
      NSLog(@"[FlutterPlaza CodePush] Removed stale patch at boot "
            @"(bundle newer than patch: %@ > %@)",
            bundleMtime, patchMtime);
    } else {
      NSLog(@"[FlutterPlaza CodePush] Failed to remove stale patch: %@",
            delError.localizedDescription);
    }

    // Remove sibling files the engine may have written alongside the
    // patch so the next launch starts from a clean state. Ignore
    // individual failures.
    for (NSString *sibling in @[
           @"boot_counter",
           @"launch_status.json",
           @"patch_info.json",
           @"patch.vmcode.tmp"
         ]) {
      NSString *siblingPath =
          [patchDirPath stringByAppendingPathComponent:sibling];
      if ([fileManager fileExistsAtPath:siblingPath]) {
        [fileManager removeItemAtPath:siblingPath error:nil];
      }
    }
  }
}

@end

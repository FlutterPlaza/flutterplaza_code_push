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

+ (NSDate *)fcpBundleFreshnessDate {
  // Compute the MAX of the mtimes of the Runner shell and the
  // App.framework/App AOT snapshot. iOS replaces the entire `.app`
  // bundle on install/upgrade, so whichever of the two is newest
  // represents "when the current code was last touched":
  //
  //   * Native-only rebuild → Runner advances
  //   * Dart-only rebuild   → App.framework/App advances
  //   * Full build          → both advance
  //
  // Either file missing is tolerated; we use whichever we find.
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSBundle *mainBundle = [NSBundle mainBundle];
  NSDate *bundleMtime = nil;

  NSString *runnerPath = [mainBundle executablePath];
  if (runnerPath) {
    NSDate *runnerMtime =
        [[fileManager attributesOfItemAtPath:runnerPath error:nil]
            fileModificationDate];
    if (runnerMtime) {
      bundleMtime = runnerMtime;
    }
  }

  NSString *appFrameworkPath =
      [[mainBundle bundlePath] stringByAppendingPathComponent:
                                   @"Frameworks/App.framework/App"];
  NSDate *appFrameworkMtime =
      [[fileManager attributesOfItemAtPath:appFrameworkPath error:nil]
          fileModificationDate];
  if (appFrameworkMtime) {
    if (!bundleMtime ||
        [appFrameworkMtime compare:bundleMtime] == NSOrderedDescending) {
      bundleMtime = appFrameworkMtime;
    }
  }
  return bundleMtime;
}

+ (void)fcpCleanupStalePatchBeforeEngineBoots {
  NSFileManager *fileManager = [NSFileManager defaultManager];

  // Locate the patch directory. The custom Flutter engine hardcodes
  // it to `<NSDocumentDirectory>/code_push_patches` (see
  // FlutterDartProject.mm in the engine fork).
  NSArray<NSString *> *documentPaths = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES);
  if (documentPaths.count == 0) {
    return;
  }
  NSString *patchDirPath =
      [documentPaths.firstObject stringByAppendingPathComponent:@"code_push_patches"];

  // Delete stale or legacy patch files before the engine boots.
  // See internal docs for details on the iOS patch lifecycle.

  // Remove legacy patch file unconditionally (crash hazard on iOS).
  NSString *legacyPatch =
      [patchDirPath stringByAppendingPathComponent:@"patch.vmcode"];
  if ([fileManager fileExistsAtPath:legacyPatch]) {
    NSError *delError = nil;
    if ([fileManager removeItemAtPath:legacyPatch error:&delError]) {
      NSLog(@"[FlutterPlaza CodePush] Deleted legacy patch.vmcode "
            @"(crash hazard on iOS cold boot)");
    } else {
      NSLog(@"[FlutterPlaza CodePush] Failed to delete legacy "
            @"patch.vmcode: %@",
            delError.localizedDescription);
    }
  }

  // Stale-vs-bundle check for the new patch.bytecode filename.
  NSString *patchPath =
      [patchDirPath stringByAppendingPathComponent:@"patch.bytecode"];
  if (![fileManager fileExistsAtPath:patchPath]) {
    return;
  }
  NSDate *patchMtime =
      [[fileManager attributesOfItemAtPath:patchPath error:nil]
          fileModificationDate];
  if (!patchMtime) {
    return;
  }
  NSDate *bundleMtime = [self fcpBundleFreshnessDate];
  if (!bundleMtime) {
    // Can't determine bundle freshness — fall through to the
    // three-strike auto-rollback safety net.
    return;
  }
  if ([bundleMtime compare:patchMtime] != NSOrderedDescending) {
    // Patch is newer than (or same age as) the bundle → keep it.
    return;
  }

  // Bundle newer than patch → patch was written by a previous install
  // and may be incompatible with the current engine/baseline. Delete
  // it and its siblings so the engine boots clean. The SDK will
  // re-download a compatible patch on the next `checkAndInstall`.
  NSError *delError = nil;
  if ([fileManager removeItemAtPath:patchPath error:&delError]) {
    NSLog(@"[FlutterPlaza CodePush] Removed stale patch.bytecode at "
          @"boot (bundle newer than patch: %@ > %@)",
          bundleMtime, patchMtime);
  } else {
    NSLog(@"[FlutterPlaza CodePush] Failed to remove stale "
          @"patch.bytecode: %@",
          delError.localizedDescription);
  }
  for (NSString *sibling in @[
         @"boot_counter",
         @"launch_status.json",
         @"patch_info.json",
         @"patch.vmcode.tmp",
         @"patch.bytecode.tmp"
       ]) {
    NSString *siblingPath =
        [patchDirPath stringByAppendingPathComponent:sibling];
    if ([fileManager fileExistsAtPath:siblingPath]) {
      [fileManager removeItemAtPath:siblingPath error:nil];
    }
  }
}

@end

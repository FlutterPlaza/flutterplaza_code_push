#import "FlutterplazaCodePushPlugin.h"

@implementation FlutterplazaCodePushPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  // Intentional no-op.
  //
  // The purpose of this class is solely to get `flutterplaza_code_push`
  // recognised by Flutter's plugin registration system, which links the
  // pod's framework into the app binary. As a side effect, dyld loads
  // the framework at process start, which runs the `+load` method on
  // `FlutterplazaCodePushBootCleanup` — that's where the actual work
  // (deleting stale patch.vmcode before the Flutter engine boots) is
  // done.
  //
  // We cannot put the cleanup here because `+registerWithRegistrar:` is
  // called AFTER the Flutter engine has been instantiated, which is too
  // late. The engine's custom boot path loads `patch.vmcode` as part of
  // isolate initialization; by the time this method runs, the stale
  // patch has already been mapped into the VM and the abort has
  // happened. `+load` on a framework class is the earliest hook we can
  // reliably get from Dart-land — it runs during dyld image loading,
  // before `main()` in the ObjC entry point.
}

@end

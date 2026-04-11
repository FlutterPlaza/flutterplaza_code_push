#import <Flutter/Flutter.h>

/// Minimal FlutterPlugin class for flutterplaza_code_push.
///
/// This class exists to satisfy Flutter's plugin registration system so
/// the pod's framework is linked into the app binary. It is NOT where
/// the actual work happens — the real fix is in the `+load` method of
/// `FlutterplazaCodePushBootCleanup`, which runs during dyld image
/// load, well before this plugin's `+registerWithRegistrar:` is ever
/// called.
@interface FlutterplazaCodePushPlugin : NSObject<FlutterPlugin>
@end

#import "FlutterplazaCodePushPlugin.h"

@implementation FlutterplazaCodePushPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel =
      [FlutterMethodChannel methodChannelWithName:@"flutterplaza_code_push"
                                  binaryMessenger:[registrar messenger]];
  FlutterplazaCodePushPlugin* instance = [[FlutterplazaCodePushPlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([@"getBaselineId" isEqualToString:call.method]) {
    NSString* baselineId =
        [[NSBundle mainBundle] objectForInfoDictionaryKey:@"FCPBaselineId"];
    result(baselineId);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

@end

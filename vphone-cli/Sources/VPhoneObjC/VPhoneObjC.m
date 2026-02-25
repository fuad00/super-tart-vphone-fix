// VPhoneObjC.m — ObjC wrappers for private Virtualization.framework APIs
#import "VPhoneObjC.h"
#import <objc/message.h>

// Private class forward declarations
@interface _VZMacHardwareModelDescriptor : NSObject
- (instancetype)init;
- (void)setPlatformVersion:(unsigned int)version;
- (void)setISA:(long long)isa;
- (void)setBoardID:(unsigned int)boardID;
@end

@interface VZMacHardwareModel (Private)
+ (instancetype)_hardwareModelWithDescriptor:(id)descriptor;
@end

@interface VZMacOSVirtualMachineStartOptions (Private)
- (void)_setForceDFU:(BOOL)force;
- (void)_setPanicAction:(BOOL)stop;
- (void)_setFatalErrorAction:(BOOL)stop;
- (void)_setStopInIBootStage1:(BOOL)stop;
- (void)_setStopInIBootStage2:(BOOL)stop;
@end

@interface VZMacOSBootLoader (Private)
- (void)_setROMURL:(NSURL *)url;
@end

@interface VZVirtualMachineConfiguration (Private)
- (void)_setDebugStub:(id)stub;
- (void)_setPanicDevice:(id)device;
- (void)_setCoprocessors:(NSArray *)coprocessors;
@end

@interface VZMacPlatformConfiguration (Private)
- (void)_setProductionModeEnabled:(BOOL)enabled;
@end

// --- Implementation ---

VZMacHardwareModel *VPhoneCreateHardwareModel(void) {
  // Create descriptor with PV=3
  _VZMacHardwareModelDescriptor *desc = [[_VZMacHardwareModelDescriptor alloc] init];
  [desc setPlatformVersion:3];
  [desc setISA:1]; // ARM64

  // Build hardware model from descriptor
  // The framework fills in defaults: boardID=0x90, minHostOS=15.0.0
  VZMacHardwareModel *model = [VZMacHardwareModel _hardwareModelWithDescriptor:desc];
  return model;
}

void VPhoneSetBootLoaderROMURL(VZMacOSBootLoader *bootloader, NSURL *romURL) {
  [bootloader _setROMURL:romURL];
}

void VPhoneConfigureStartOptions(VZMacOSVirtualMachineStartOptions *opts,
                                  BOOL stopOnPanic,
                                  BOOL stopOnFatalError) {
  [opts _setForceDFU:YES];
  [opts _setStopInIBootStage1:NO];
  [opts _setStopInIBootStage2:NO];
  // Note: _setPanicAction: / _setFatalErrorAction: don't exist on
  // VZMacOSVirtualMachineStartOptions. Panic handling is done via
  // _VZPvPanicDeviceConfiguration set on VZVirtualMachineConfiguration.
}

void VPhoneSetGDBDebugStub(VZVirtualMachineConfiguration *config, NSInteger port) {
  Class stubClass = NSClassFromString(@"_VZGDBDebugStubConfiguration");
  if (!stubClass) {
    NSLog(@"[vphone] WARNING: _VZGDBDebugStubConfiguration not found");
    return;
  }
  // Use objc_msgSend to call initWithPort: with an NSInteger argument
  id (*initWithPort)(id, SEL, NSInteger) = (id (*)(id, SEL, NSInteger))objc_msgSend;
  id stub = initWithPort([stubClass alloc], NSSelectorFromString(@"initWithPort:"), port);
  [config _setDebugStub:stub];
}

void VPhoneSetPanicDevice(VZVirtualMachineConfiguration *config) {
  Class panicClass = NSClassFromString(@"_VZPvPanicDeviceConfiguration");
  if (!panicClass) {
    NSLog(@"[vphone] WARNING: _VZPvPanicDeviceConfiguration not found");
    return;
  }
  id device = [[panicClass alloc] init];
  [config _setPanicDevice:device];
}

void VPhoneSetCoprocessors(VZVirtualMachineConfiguration *config, NSArray *coprocessors) {
  [config _setCoprocessors:coprocessors];
}

void VPhoneDisableProductionMode(VZMacPlatformConfiguration *platform) {
  [platform _setProductionModeEnabled:NO];
}

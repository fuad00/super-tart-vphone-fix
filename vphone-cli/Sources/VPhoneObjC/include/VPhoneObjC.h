// VPhoneObjC.h — ObjC wrappers for private Virtualization.framework APIs
#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>

NS_ASSUME_NONNULL_BEGIN

/// Create a PV=3 (vphone) VZMacHardwareModel using private _VZMacHardwareModelDescriptor.
VZMacHardwareModel *VPhoneCreateHardwareModel(void);

/// Set _setROMURL: on a VZMacOSBootLoader.
void VPhoneSetBootLoaderROMURL(VZMacOSBootLoader *bootloader, NSURL *romURL);

/// Configure VZMacOSVirtualMachineStartOptions for DFU mode.
/// Sets _setForceDFU:YES, _setPanicAction:, _setFatalErrorAction:
void VPhoneConfigureStartOptions(VZMacOSVirtualMachineStartOptions *opts,
                                  BOOL stopOnPanic,
                                  BOOL stopOnFatalError);

/// Set _setDebugStub: with a _VZGDBDebugStubConfiguration on the VM config.
void VPhoneSetGDBDebugStub(VZVirtualMachineConfiguration *config, NSInteger port);

/// Set _VZPvPanicDeviceConfiguration on the VM config.
void VPhoneSetPanicDevice(VZVirtualMachineConfiguration *config);

/// Set _setCoprocessors: on the VM config (empty array = no coprocessors).
void VPhoneSetCoprocessors(VZVirtualMachineConfiguration *config, NSArray *coprocessors);

/// Set _setProductionModeEnabled:NO on VZMacPlatformConfiguration.
void VPhoneDisableProductionMode(VZMacPlatformConfiguration *platform);

NS_ASSUME_NONNULL_END

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

/// Create a _VZSEPCoprocessorConfiguration with the given storage URL.
/// Returns the config object, or nil on failure.
id _Nullable VPhoneCreateSEPCoprocessorConfig(NSURL *storageURL);

/// Set romBinaryURL on a _VZSEPCoprocessorConfiguration.
void VPhoneSetSEPRomBinaryURL(id sepConfig, NSURL *romURL);

/// Configure SEP coprocessor on the VM config.
/// Creates storage at sepStorageURL, optionally sets sepRomURL, and calls _setCoprocessors:.
void VPhoneConfigureSEP(VZVirtualMachineConfiguration *config,
                        NSURL *sepStorageURL,
                        NSURL *_Nullable sepRomURL);

NS_ASSUME_NONNULL_END

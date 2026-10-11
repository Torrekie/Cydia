// Modified work Copyright (C) 2026 Torrekie
// SPDX-License-Identifier: GPL-3.0-or-later
//
// MobileGestalt key inventory adapted from zbrateam/Firmware (GPL-3.0),
// commit c6c0485c8f575a1e470767e3cb29fdf8e2de0e5e, src/MobileGestalt.m.
// This read-only collector does not use Firmware's status writer or /User setup.

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <TargetConditionals.h>
#include <dlfcn.h>
#include <mach/machine.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <cstdio>
#include <cstring>

static const char *const CydiaGestaltKeys[] = {
    "3GProximityCapability",
    "3Gvenice",
    "64-bit",
    "720p",
    "AWDLCapability",
    "ActivationProtocol",
    "AggregateDevicePhotoZoomFactor",
    "AggregateDeviceVideoZoomFactor",
    "AirDropCapability",
    "Allow32BitApps",
    "AllowOnlyATVCPSDKApps",
    "AllowYouTube",
    "AllowYouTubePlugin",
    "AppCapacityTVOS",
    "AppStore",
    "AudioPlaybackCapability",
    "BacklightCapability",
    "BasebandClass",
    "BlueLightReductionSupported",
    "BoardId",
    "BuddyLanguagesAnimationRequiresOptimization",
    "CPUSubType",
    "CPUType",
    "CameraHDR2Capability",
    "CameraLiveEffectsCapability",
    "CameraMaxBurstLength",
    "CarrierInstallCapability",
    "CellularTelephonyCapability",
    "ChipID",
    "CloudPhotoLibraryCapability",
    "CoastlineGlowRenderingCapability",
    "CompassType",
    "ContinuityCapability",
    "CoreRoutineCapability",
    "DesenseBuild",
    "DeviceBackGlassMaterial",
    "DeviceBackingColor",
    "DeviceBrand",
    "DeviceClassNumber",
    "DeviceColor",
    "DeviceColorMapPolicy",
    "DeviceCornerRadius",
    "DeviceCoverGlassColor",
    "DeviceCoverGlassMaterial",
    "DeviceCoverMaterial",
    "DeviceEnclosureColor",
    "DeviceEnclosureMaterial",
    "DeviceHasAggregateCamera",
    "DeviceHousingColor",
    "DeviceLaunchTimeLimitScale",
    "DevicePrefers3DBuildingStrokes",
    "DevicePrefersBuildingStrokes",
    "DevicePrefersCheapTrafficShaders",
    "DevicePrefersProceduralAntiAliasing",
    "DevicePrefersTrafficAlpha",
    "DeviceRequiresPetalOptimization",
    "DeviceRequiresProximityAmeliorations",
    "DeviceRequiresSoftwareBrightnessCalculations",
    "DeviceSceneUpdateTimeLimitScale",
    "DeviceSubBrand",
    "DeviceSupports1080p",
    "DeviceSupports3DImagery",
    "DeviceSupports3DMaps",
    "DeviceSupports4G",
    "DeviceSupports4k",
    "DeviceSupports720p",
    "DeviceSupports9Pin",
    "DeviceSupportsAOP",
    "DeviceSupportsASTC",
    "DeviceSupportsAdaptiveMapsUI",
    "DeviceSupportsAlwaysListening",
    "DeviceSupportsAlwaysOnCompass",
    "DeviceSupportsApplePencil",
    "DeviceSupportsAutoLowLightVideo",
    "DeviceSupportsBatteryModuleAuthentication",
    "DeviceSupportsBerkelium2",
    "DeviceSupportsCCK",
    "DeviceSupportsCameraCaptureOnTouchDown",
    "DeviceSupportsCameraHaptics",
    "DeviceSupportsCarIntegration",
    "DeviceSupportsCinnamon",
    "DeviceSupportsClosedLoopHaptics",
    "DeviceSupportsCrudeProx",
    "DeviceSupportsDClr",
    "DeviceSupportsDoNotDisturbWhileDriving",
    "DeviceSupportsELabel",
    "DeviceSupportsEnhancedAC3",
    "DeviceSupportsFloorCounting",
    "DeviceSupportsHaptics",
    "DeviceSupportsHeartHealthAlerts",
    "DeviceSupportsHeartRateVariability",
    "DeviceSupportsHiResBuildings",
    "DeviceSupportsLineIn",
    "DeviceSupportsLiquidDetection_CorrosionMitigation",
    "DeviceSupportsLivePhotoAuto",
    "DeviceSupportsMapsBlurredUI",
    "DeviceSupportsNavigation",
    "DeviceSupportsNewton",
    "DeviceSupportsPeriodicALSUpdates",
    "DeviceSupportsPortraitLightEffectFilters",
    "DeviceSupportsRGB10",
    "DeviceSupportsRaiseToSpeak",
    "DeviceSupportsSiDP",
    "DeviceSupportsSimplisticRoadMesh",
    "DeviceSupportsSingleCameraPortrait",
    "DeviceSupportsSiriSpeaks",
    "DeviceSupportsStereoAudioRecording",
    "DeviceSupportsStudioLightPortraitPreview",
    "DeviceSupportsSwimmingWorkouts",
    "DeviceSupportsTapToWake",
    "DeviceSupportsTethering",
    "DeviceSupportsToneMapping",
    "DeviceSupportsUSBTypeC",
    "DeviceSupportsWebkit",
    "DeviceSupportsYCbCr10",
    "DeviceVariant",
    "DeviceVariantGuess",
    "ExternalChargeCapability",
    "FDRSealingStatus",
    "FMFAllowed",
    "FaceTimeBackCameraTemporalNoiseReductionMode",
    "FaceTimeCameraRequiresFastSwitchOptions",
    "FaceTimeCameraSupportsHardwareFaceDetection",
    "FaceTimeFrontCameraTemporalNoiseReductionMode",
    "FaceTimePhotosOptIn",
    "FirstPartyLaunchTimeLimitScale",
    "ForwardCameraCapability",
    "FrontFacingCameraAutoHDRCapability",
    "FrontFacingCameraBurstCapability",
    "FrontFacingCameraHDRCapability",
    "FrontFacingCameraHDROnCapability",
    "FrontFacingCameraHFRCapability",
    "FrontFacingCameraMaxVideoZoomFactor",
    "FrontFacingCameraStillDurationForBurst",
    "FrontFacingCameraVideoCapture1080pMaxFPS",
    "FrontFacingCameraVideoCapture4kMaxFPS",
    "FrontFacingCameraVideoCapture720pMaxFPS",
    "H264EncoderCapability",
    "HEVCDecoder10bitSupported",
    "HEVCDecoder12bitSupported",
    "HEVCDecoder8bitSupported",
    "HEVCEncodingCapability",
    "HasAppleNeuralEngine",
    "HasBaseband",
    "HasBattery",
    "HasDaliMode",
    "HasExtendedColorDisplay",
    "HasIcefall",
    "HasMesa",
    "HasPKA",
    "HasSEP",
    "HasSpringBoard",
    "HasThinBezel",
    "HighestSupportedVideoMode",
    "HomeButtonType",
    "IDAMCapability",
    "IcefallInRestrictedMode",
    "Image4Supported",
    "IsEmulatedDevice",
    "IsLargeFormatPhone",
    "IsPwrOpposedVol",
    "IsSimulator",
    "IsUIBuild",
    "LaunchTimeLimitScaleSupported",
    "LisaCapability",
    "MainDisplayRotation",
    "MaxH264PlaybackLevel",
    "MaximumScreenScale",
    "MedusaFloatingLiveAppCapability",
    "MedusaOverlayAppCapability",
    "MedusaPIPCapability",
    "MedusaPinnedAppCapability",
    "MicrophoneCount",
    "MinimumSupportediTunesVersion",
    "MixAndMatchPrevention",
    "MobileDeviceMinimumVersion",
    "MonarchLowEndHardware",
    "MusicStore",
    "N78aHack",
    "NFCRadioCalibrationDataPresent",
    "NavajoFusingState",
    "OLEDDisplay",
    "OfflineDictationCapability",
    "OpenGLESVersion",
    "PanoramaCameraCapability",
    "PearlIDCapability",
    "PeekUICapability",
    "PhosphorusCapability",
    "PhotoCapability",
    "PhotoSharingCapability",
    "PhotosPostEffectsCapability",
    "PipelinedStillImageProcessingCapability",
    "PlatinumCapability",
    "ProductVersion",
    "RFExposureSeparationDistance",
    "RearCameraCapability",
    "RearFacingCamera60fpsVideoCaptureCapability",
    "RearFacingCameraAutoHDRCapability",
    "RearFacingCameraBurstCapability",
    "RearFacingCameraHDRCapability",
    "RearFacingCameraHDROnCapability",
    "RearFacingCameraHFRCapability",
    "RearFacingCameraHFRVideoCapture1080pMaxFPS",
    "RearFacingCameraHFRVideoCapture720pMaxFPS",
    "RearFacingCameraMaxVideoZoomFactor",
    "RearFacingCameraStillDurationForBurst",
    "RearFacingCameraVideoCapture1080pMaxFPS",
    "RearFacingCameraVideoCapture4kMaxFPS",
    "RearFacingCameraVideoCapture720pMaxFPS",
    "RearFacingCameraVideoCaptureFPS",
    "RearFacingTelephotoCameraCapability",
    "RegionalBehaviorChinaBrick",
    "RegionalBehaviorEUVolumeLimit",
    "RegionalBehaviorGB18030",
    "RegionalBehaviorGoogleMail",
    "RegionalBehaviorNTSC",
    "RegionalBehaviorNoPasscodeLocationTiles",
    "RegionalBehaviorNoVOIP",
    "RegionalBehaviorNoWiFi",
    "RegionalBehaviorShutterClick",
    "RegionalBehaviorValid",
    "RegionalBehaviorVolumeLimit",
    "RenderWideGamutImagesAtDisplayTime",
    "RendersLetterPressSlowly",
    "RestoreOSBuild",
    "RotateToWakeStatus",
    "SBAllowSensitiveUI",
    "SBCanForceDebuggingInfo",
    "ScreenRecorderCapability",
    "SecureElement",
    "ShouldHactivate",
    "SiKACapability",
    "SigningFuse",
    "SiliconBringupBoard",
    "SiriOfflineCapability",
    "Skey",
    "SoftwareBundleVersion",
    "SoftwareDimmingAlpha",
    "SphereCapability",
    "StarkCapability",
    "SupportsBurninMitigation",
    "SupportsEDUMU",
    "SupportsForceTouch",
    "SupportsIrisCapture",
    "SupportsLowPowerMode",
    "SupportsPerseus",
    "SupportsRotateToWake",
    "SupportsSOS",
    "SupportsSSHBButtonType",
    "SupportsTouchRemote",
    "TimeSyncCapability",
    "TouchDelivery120Hz",
    "UIBackgroundQuality",
    "UIParallaxCapability",
    "UIProceduralWallpaperCapability",
    "UIReachability",
    "VibratorCapability",
    "WAGraphicQuality",
    "WLANBkgScanCache",
    "WifiChipset",
    "WirelessChargingCapability",
    "accelerometer",
    "accessibility",
    "additional-text-tones",
    "airDropRestriction",
    "airplay-mirroring",
    "all-features",
    "ambient-light-sensor",
    "any-telephony",
    "applicationInstallation",
    "arkit",
    "arm64",
    "armv6",
    "armv7",
    "armv7s",
    "assistant",
    "auto-focus-camera",
    "bluetooth",
    "bluetooth-le",
    "camera-flash",
    "camera-front-flash",
    "cameraRestriction",
    "cellular-data",
    "contains-cellular-radio",
    "data-plan",
    "delay-sleep-for-headset-click",
    "dictation",
    "display-mirroring",
    "displayport",
    "encode-aac",
    "encrypted-data-partition",
    "enforce-googlemail",
    "enforce-shutter-click",
    "explicitContentRestriction",
    "fcc-logos-via-software",
    "front-facing-camera",
    "full-6",
    "gamekit",
    "gas-gauge-battery",
    "gps",
    "green-tea",
    "gyroscope",
    "hall-effect-sensor",
    "haptics",
    "hardware-keyboard",
    "hd-video-capture",
    "hdr-image-capture",
    "healthkit",
    "hearingaid-audio-equalization",
    "hearingaid-low-energy-audio",
    "hearingaid-power-reduction",
    "hiccough-interval",
    "hide-non-default-apps",
    "hidpi",
    "homescreen-wallpaper",
    "hw-encode-snapshots",
    "hw-snapshots-need-purplegfx",
    "iAP2Capability",
    "international-settings",
    "io-surface-backed-images",
    "load-thumbnails-while-scrolling",
    "location-reminders",
    "location-services",
    "magnetometer",
    "main-screen-class",
    "main-screen-height",
    "main-screen-orientation",
    "main-screen-pitch",
    "main-screen-scale",
    "main-screen-width",
    "metal",
    "microphone",
    "mms",
    "multitasking",
    "multitasking-gestures",
    "nfc",
    "nike-ipod",
    "not-green-tea",
    "opengles-1",
    "opengles-2",
    "opengles-3",
    "ota-activation",
    "peer-peer",
    "personal-hotspot",
    "photo-adjustments",
    "photo-stream",
    "piezo-clicker",
    "proximity-sensor",
    "ptp-large-files",
    "rear-facing-camera",
    "ringer-switch",
    "sensitive-ui",
    "shoebox",
    "siri-gesture",
    "sms",
    "stand-alone-contacts",
    "still-camera",
    "telephony",
    "telephony-maximum-generation",
    "touch-id",
    "tv-out-crossfade",
    "unified-ipod",
    "venice",
    "video-camera",
    "video-stills",
    "voice-control",
    "voip",
    "volume-buttons",
    "wapi",
    "wi-fi",
    "wifi",
};

static int DigestInput() {
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[16384];
    size_t count;
    while ((count = fread(buffer, 1, sizeof(buffer), stdin)) != 0)
        CC_SHA256_Update(&context, buffer, static_cast<CC_LONG>(count));
    if (ferror(stdin)) {
        fprintf(stderr, "Could not read firmware review input\n");
        return 1;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    for (unsigned char byte : digest)
        printf("%02x", byte);
    putchar('\n');
    return ferror(stdout) ? 1 : 0;
}

static NSString *CPUName(cpu_type_t type, cpu_subtype_t subtype) {
    subtype &= ~CPU_SUBTYPE_MASK;
    if (type == CPU_TYPE_ARM64) {
        switch (subtype) {
            case CPU_SUBTYPE_ARM64_ALL: return @"arm64";
            case CPU_SUBTYPE_ARM64_V8: return @"arm64v8";
            case CPU_SUBTYPE_ARM64E: return @"arm64e";
        }
    } else if (type == CPU_TYPE_ARM) {
        switch (subtype) {
            case CPU_SUBTYPE_ARM_ALL: return @"arm";
            case CPU_SUBTYPE_ARM_V6: return @"armv6";
            case CPU_SUBTYPE_ARM_V7: return @"armv7";
            case CPU_SUBTYPE_ARM_V7S: return @"armv7s";
            case CPU_SUBTYPE_ARM_V7K: return @"armv7k";
        }
    } else if (type == CPU_TYPE_X86_64 && subtype == CPU_SUBTYPE_X86_64_ALL) {
        return @"x86_64";
    }
    return nil;
}

static void Identity(NSString *package, NSString *version) {
    printf("identity\t%s\t%s\n", package.UTF8String, version.UTF8String);
}

static int Discover() {
    cpu_type_t type = 0;
    cpu_subtype_t subtype = 0;
    size_t size = sizeof(type);
    if (sysctlbyname("hw.cputype", &type, &size, nullptr, 0) != 0) {
        fprintf(stderr, "Could not read hardware CPU type\n");
        return 1;
    }
    size = sizeof(subtype);
    if (sysctlbyname("hw.cpusubtype", &subtype, &size, nullptr, 0) != 0) {
        fprintf(stderr, "Could not read hardware CPU subtype\n");
        return 1;
    }
    NSString *base = type == CPU_TYPE_ARM64 ? @"arm64" :
        type == CPU_TYPE_ARM ? @"arm" : type == CPU_TYPE_X86_64 ? @"x86_64" : nil;
    NSString *specific = CPUName(type, subtype);
    struct utsname system = {};
    if (base == nil || specific == nil || uname(&system) != 0) {
        fprintf(stderr, "Unsupported hardware CPU identity or unavailable kernel identity\n");
        return 1;
    }

    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (gestalt == nullptr) {
        fprintf(stderr, "MobileGestalt discovery is unavailable\n");
        return 1;
    }
    typedef CFTypeRef (*CopyAnswer)(CFStringRef);
    CopyAnswer copyAnswer = reinterpret_cast<CopyAnswer>(dlsym(gestalt, "MGCopyAnswer"));
    typedef bool (*BoolAnswer)(CFStringRef);
    BoolAnswer boolAnswer = reinterpret_cast<BoolAnswer>(dlsym(gestalt, "MGGetBoolAnswer"));
    if (copyAnswer == nullptr) {
        fprintf(stderr, "MobileGestalt answer API is unavailable\n");
        dlclose(gestalt);
        return 1;
    }

    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    NSString *version = os.patchVersion == 0 ?
        [NSString stringWithFormat:@"%ld.%ld", (long)os.majorVersion, (long)os.minorVersion] :
        [NSString stringWithFormat:@"%ld.%ld.%ld", (long)os.majorVersion,
            (long)os.minorVersion, (long)os.patchVersion];
    NSString *model = [NSString stringWithUTF8String:system.machine];
    NSRegularExpression *modelPattern = [NSRegularExpression
        regularExpressionWithPattern:@"^([A-Za-z]+)([0-9]+),([0-9]+)$" options:0 error:nullptr];
    NSTextCheckingResult *match = [modelPattern firstMatchInString:model options:0
        range:NSMakeRange(0, model.length)];
    if (match == nil) {
        fprintf(stderr, "Unsupported hardware model identity\n");
        dlclose(gestalt);
        return 1;
    }

    Identity(@"firmware", version);
    Identity(@"cy+os.iphoneos", version);
    Identity([@"cy+cpu." stringByAppendingString:base], @"0");
    if (![specific isEqualToString:base])
        Identity([@"cy+cpu." stringByAppendingString:specific], @"0");
    NSString *modelName = [[model substringWithRange:[match rangeAtIndex:1]] lowercaseString];
    NSString *modelVersion = [NSString stringWithFormat:@"%@.%@",
        [model substringWithRange:[match rangeAtIndex:2]],
        [model substringWithRange:[match rangeAtIndex:3]]];
    Identity([@"cy+model." stringByAppendingString:modelName], modelVersion);
    NSString *kernel = [[NSString stringWithUTF8String:system.sysname] lowercaseString];
    Identity([@"cy+kernel." stringByAppendingString:kernel],
        [NSString stringWithUTF8String:system.release]);
    Identity(@"cy+lib.corefoundation",
        [NSString stringWithFormat:@"%.2f", kCFCoreFoundationVersionNumber]);

    NSRegularExpression *integer = [NSRegularExpression
        regularExpressionWithPattern:@"^[0-9]+$" options:0 error:nullptr];
    NSRegularExpression *decimal = [NSRegularExpression
        regularExpressionWithPattern:@"^[0-9]+(?:\\.[0-9]+)*$" options:0 error:nullptr];
    for (const char *key : CydiaGestaltKeys) {
        NSString *question = [NSString stringWithUTF8String:key];
        id answer = CFBridgingRelease(copyAnswer((__bridge CFStringRef)question));
        NSString *numeric = nil;
        NSRegularExpression *pattern = integer;
        if ([answer isKindOfClass:NSNumber.class]) {
            if ([(NSNumber *)answer compare:@0] == NSOrderedSame)
                continue;
            numeric = [(NSNumber *)answer stringValue];
            pattern = decimal;
        } else if ([answer isKindOfClass:NSString.class]) {
            numeric = answer;
        }
        if (numeric == nil || [numeric isEqualToString:@"0"])
            continue;
        if ([pattern firstMatchInString:numeric options:0
                range:NSMakeRange(0, numeric.length)] != nil)
            printf("gestalt\t%s\t%s\n", key, numeric.UTF8String);
    }

    bool ipad = false;
    if (boolAnswer != nullptr) {
        ipad = boolAnswer(CFSTR("ipad"));
    } else {
        id answer = CFBridgingRelease(copyAnswer(CFSTR("ipad")));
        if ([answer isKindOfClass:NSNumber.class])
            ipad = [(NSNumber *)answer boolValue];
    }
    if (ipad)
        printf("gestalt\tipad\t1\n");
    dlclose(gestalt);
    return ferror(stdout) ? 1 : 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--digest") == 0)
            return DigestInput();
        if (argc != 1) {
            fprintf(stderr, "Usage: firmware-discovery [--digest]\n");
            return 64;
        }
        return Discover();
    }
}

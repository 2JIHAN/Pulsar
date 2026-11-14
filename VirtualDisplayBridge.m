#import "VirtualDisplayBridge.h"
#import <objc/runtime.h>
#import <stdatomic.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property unsigned int vendorID, productID, serialNum, serialNumber, maxPixelsWide, maxPixelsHigh;
@property(strong) NSString *name;
@property CGSize sizeInMillimeters;
@property CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(strong) dispatch_queue_t queue;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property unsigned int hiDPI, rotation;
@property(strong) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly) unsigned int displayID;
@end

static atomic_uint nextVirtualDisplaySerial = 0;

BOOL PulsarVirtualDisplayAPIAvailable(void) {
    NSDictionary<NSString *, NSArray<NSString *> *> *required = @{
        @"CGVirtualDisplayDescriptor": @[
            @"setVendorID:", @"setProductID:", @"setSerialNum:", @"setSerialNumber:",
            @"setName:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:", @"setSizeInMillimeters:",
            @"setQueue:", @"setRedPrimary:", @"setGreenPrimary:", @"setBluePrimary:", @"setWhitePoint:"
        ],
        @"CGVirtualDisplayMode": @[@"initWithWidth:height:refreshRate:"],
        @"CGVirtualDisplaySettings": @[@"setHiDPI:", @"setRotation:", @"setModes:"],
        @"CGVirtualDisplay": @[@"initWithDescriptor:", @"applySettings:", @"displayID"]
    };
    for (NSString *className in required) {
        Class cls = NSClassFromString(className);
        if (!cls) return NO;
        for (NSString *selName in required[className]) {
            if (!class_getInstanceMethod(cls, NSSelectorFromString(selName))) return NO;
        }
    }
    return YES;
}

NSObject * _Nullable PulsarCreateVirtualDisplay(unsigned int pixelWidth, unsigned int pixelHeight, unsigned int scale, uint32_t *outDisplayID) {
    if (outDisplayID) *outDisplayID = 0;
    if (!PulsarVirtualDisplayAPIAvailable()) return nil;
    if (pixelWidth < 640 || pixelWidth > 6016 || pixelHeight < 480 || pixelHeight > 3384) return nil;
    if (scale != 1 && scale != 2) return nil;

    unsigned int serial = atomic_fetch_add(&nextVirtualDisplaySerial, 1) + 1;
    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    if (!descriptor) return nil;
    descriptor.vendorID = 0x5055;
    descriptor.productID = 0x4C53;
    descriptor.serialNum = serial;
    descriptor.serialNumber = serial;
    descriptor.name = @"Pulsar";
    descriptor.maxPixelsWide = pixelWidth;
    descriptor.maxPixelsHigh = pixelHeight;
    double ppi = (scale == 2) ? 220.0 : 96.0;
    descriptor.sizeInMillimeters = CGSizeMake(pixelWidth * 25.4 / ppi, pixelHeight * 25.4 / ppi);
    descriptor.redPrimary = CGPointMake(0.64, 0.33);
    descriptor.greenPrimary = CGPointMake(0.30, 0.60);
    descriptor.bluePrimary = CGPointMake(0.15, 0.06);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!display) return nil;

    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    if (!settings) return nil;
    settings.hiDPI = (scale == 2) ? 1 : 0;
    settings.rotation = 0;

    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (scale == 2) {
        id physicalAnchor = [[modeClass alloc] initWithWidth:pixelWidth height:pixelHeight refreshRate:60.0];
        id logicalMode = [[modeClass alloc] initWithWidth:pixelWidth / 2 height:pixelHeight / 2 refreshRate:60.0];
        if (!physicalAnchor || !logicalMode) return nil;
        settings.modes = @[physicalAnchor, logicalMode];
    } else {
        id mode = [[modeClass alloc] initWithWidth:pixelWidth height:pixelHeight refreshRate:60.0];
        if (!mode) return nil;
        settings.modes = @[mode];
    }

    if (![display applySettings:settings]) return nil;
    uint32_t displayID = display.displayID;
    if (displayID == 0) return nil;
    if (outDisplayID) *outDisplayID = displayID;
    return display;
}

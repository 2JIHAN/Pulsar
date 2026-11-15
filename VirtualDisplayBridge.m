#import "VirtualDisplayBridge.h"
#import <objc/runtime.h>
#import <stdatomic.h>
#import <math.h>
#import <limits.h>

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


// Startup-only preservation. CoreGraphics can mirror an existing root to a new
// virtual display before applySettings returns. Never replay this after startup.
typedef struct {
    CGDirectDisplayID id, mirror;
    uint32_t vendor, model, serial;
    BOOL active;
    CGRect bounds;
    CGDisplayModeRef mode;
} PulsarPriorDisplay;

typedef struct {
    PulsarPriorDisplay displays[32];
    uint32_t count;
    CGDirectDisplayID main;
    CGRect bounds;
} PulsarPriorLayout;

static BOOL PulsarModeMatches(CGDisplayModeRef a, CGDisplayModeRef b) {
    return a && b && CGDisplayModeGetWidth(a) == CGDisplayModeGetWidth(b)
        && CGDisplayModeGetHeight(a) == CGDisplayModeGetHeight(b)
        && CGDisplayModeGetPixelWidth(a) == CGDisplayModeGetPixelWidth(b)
        && CGDisplayModeGetPixelHeight(a) == CGDisplayModeGetPixelHeight(b)
        && fabs(CGDisplayModeGetRefreshRate(a) - CGDisplayModeGetRefreshRate(b)) < 0.01
        && CGDisplayModeGetIOFlags(a) == CGDisplayModeGetIOFlags(b);
}

static void PulsarReleaseLayout(PulsarPriorLayout *layout) {
    for (uint32_t i = 0; i < layout->count; i++)
        if (layout->displays[i].mode) CGDisplayModeRelease(layout->displays[i].mode);
}

static BOOL PulsarOnlineMatches(PulsarPriorLayout *layout, CGDirectDisplayID owned) {
    CGDirectDisplayID ids[32]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, ids, &count) != kCGErrorSuccess
        || count != layout->count + (owned != 0)) return NO;
    BOOL ownedPresent = owned == 0;
    for (uint32_t j = 0; j < count; j++) {
        if (owned && ids[j] == owned) { ownedPresent = YES; continue; }
        BOOL known = NO;
        for (uint32_t i = 0; i < layout->count; i++) {
            PulsarPriorDisplay *d = &layout->displays[i];
            if (ids[j] != d->id) continue;
            known = CGDisplayVendorNumber(d->id) == d->vendor
                && CGDisplayModelNumber(d->id) == d->model
                && CGDisplaySerialNumber(d->id) == d->serial;
            break;
        }
        if (!known) return NO;
    }
    return ownedPresent;
}

static BOOL PulsarLayoutMatches(PulsarPriorLayout *layout, CGDirectDisplayID owned, BOOL modes) {
    if (!PulsarOnlineMatches(layout, owned) || CGMainDisplayID() != layout->main) return NO;
    for (uint32_t i = 0; i < layout->count; i++) {
        PulsarPriorDisplay *d = &layout->displays[i];
        if (CGDisplayMirrorsDisplay(d->id) != d->mirror
            || (CGDisplayIsActive(d->id) != 0) != d->active) return NO;
        if (modes) {
            CGDisplayModeRef mode = CGDisplayCopyDisplayMode(d->id);
            BOOL same = CGRectEqualToRect(CGDisplayBounds(d->id), d->bounds)
                && PulsarModeMatches(mode, d->mode);
            if (mode) CGDisplayModeRelease(mode);
            if (!same) return NO;
        }
    }
    return YES;
}

static BOOL PulsarCaptureLayout(PulsarPriorLayout *layout) {
    CGDirectDisplayID ids[32]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, ids, &count) != kCGErrorSuccess || count < 1 || count > 31) return NO;
    layout->main = CGMainDisplayID(); layout->bounds = CGRectNull;
    BOOL mainFound = NO;
    for (uint32_t i = 0; i < count; i++) {
        PulsarPriorDisplay *d = &layout->displays[layout->count++];
        d->id = ids[i]; d->mirror = CGDisplayMirrorsDisplay(d->id);
        d->vendor = CGDisplayVendorNumber(d->id); d->model = CGDisplayModelNumber(d->id);
        d->serial = CGDisplaySerialNumber(d->id); d->active = CGDisplayIsActive(d->id) != 0;
        d->bounds = CGDisplayBounds(d->id); d->mode = CGDisplayCopyDisplayMode(d->id);
        if (!d->mode || CGRectIsEmpty(d->bounds) || CGRectIsInfinite(d->bounds)) return NO;
        if (!d->mirror && d->active) layout->bounds = CGRectUnion(layout->bounds, d->bounds);
        if (d->id == layout->main && d->active && !d->mirror) mainFound = YES;
    }
    // A second complete read rejects an already-changing layout before creation.
    return mainFound && !CGRectIsNull(layout->bounds) && PulsarLayoutMatches(layout, 0, YES);
}

static void PulsarSettle(void) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.35];
    while (deadline.timeIntervalSinceNow > 0)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
}

static CGDisplayModeRef PulsarFreshMode(CGDirectDisplayID id, CGDisplayModeRef saved,
                                       unsigned width, unsigned height, unsigned pixelWidth, unsigned pixelHeight) {
    NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(id, (__bridge CFDictionaryRef)options);
    CGDisplayModeRef result = NULL;
    for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        BOOL match = saved ? PulsarModeMatches(mode, saved)
            : CGDisplayModeGetWidth(mode) == width && CGDisplayModeGetHeight(mode) == height
                && CGDisplayModeGetPixelWidth(mode) == pixelWidth && CGDisplayModeGetPixelHeight(mode) == pixelHeight
                && fabs(CGDisplayModeGetRefreshRate(mode) - 60.0) < 0.01;
        if (match) { result = CGDisplayModeRetain(mode); break; }
    }
    if (modes) CFRelease(modes);
    return result;
}

static BOOL PulsarPreserveLayout(PulsarPriorLayout *layout, CGDirectDisplayID owned,
                                 unsigned pixelWidth, unsigned pixelHeight, unsigned scale) {
    if (!owned || !PulsarOnlineMatches(layout, owned)) return NO;
    for (uint32_t i = 0; i < layout->count; i++) if (layout->displays[i].id == owned) return NO;
    double left = CGRectGetMinX(layout->bounds) - pixelWidth / scale;
    double top = CGRectGetMinY(layout->bounds);
    if (!isfinite(left) || !isfinite(top) || left < INT32_MIN || left > INT32_MAX
        || top < INT32_MIN || top > INT32_MAX) return NO;
    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return NO;
    CGError error = kCGErrorSuccess;
    // Detach old roots before restoring aliases. No physical mode writes while
    // aliases still expose the temporary mirror group's effective mode table.
    for (uint32_t i = 0; i < layout->count && error == kCGErrorSuccess; i++) {
        PulsarPriorDisplay *d = &layout->displays[i];
        if (!d->mirror) error = CGConfigureDisplayMirrorOfDisplay(config, d->id, kCGNullDirectDisplay);
    }
    for (uint32_t i = 0; i < layout->count && error == kCGErrorSuccess; i++) {
        PulsarPriorDisplay *d = &layout->displays[i];
        if (!d->mirror) error = CGConfigureDisplayOrigin(config, d->id, (int32_t)d->bounds.origin.x, (int32_t)d->bounds.origin.y);
    }
    for (uint32_t i = 0; i < layout->count && error == kCGErrorSuccess; i++) {
        PulsarPriorDisplay *d = &layout->displays[i];
        if (d->mirror) error = CGConfigureDisplayMirrorOfDisplay(config, d->id, d->mirror);
    }
    if (error == kCGErrorSuccess) error = CGConfigureDisplayMirrorOfDisplay(config, owned, kCGNullDirectDisplay);
    if (error == kCGErrorSuccess) error = CGConfigureDisplayOrigin(config, owned, (int32_t)left, (int32_t)top);
    if (error != kCGErrorSuccess) { CGCancelDisplayConfiguration(config); return NO; }
    if (CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess) return NO;
    PulsarSettle();
    if (!PulsarLayoutMatches(layout, owned, NO)) return NO;

    // Re-enumerate modes after detaching. Retained pre-create mode objects may
    // commit successfully without restoring the physical mode on this OS.
    CGDisplayModeRef requested[32] = {0}; BOOL valid = YES, changed = NO;
    for (uint32_t i = 0; i < layout->count && valid; i++) {
        PulsarPriorDisplay *d = &layout->displays[i];
        if (d->mirror) continue;
        CGDisplayModeRef current = CGDisplayCopyDisplayMode(d->id);
        BOOL same = PulsarModeMatches(current, d->mode);
        if (current) CGDisplayModeRelease(current);
        if (!same) {
            requested[i] = PulsarFreshMode(d->id, d->mode, 0, 0, 0, 0);
            valid = requested[i] != NULL; changed = YES;
        }
    }
    if (valid && changed) {
        valid = PulsarLayoutMatches(layout, owned, NO) && CGBeginDisplayConfiguration(&config) == kCGErrorSuccess;
        if (valid) {
            error = kCGErrorSuccess;
            for (uint32_t i = 0; i < layout->count && error == kCGErrorSuccess; i++)
                if (requested[i]) error = CGConfigureDisplayWithDisplayMode(config, layout->displays[i].id, requested[i], NULL);
            if (error != kCGErrorSuccess) { CGCancelDisplayConfiguration(config); valid = NO; }
            else valid = CGCompleteDisplayConfiguration(config, kCGConfigureForSession) == kCGErrorSuccess;
        }
    }
    for (uint32_t i = 0; i < layout->count; i++) if (requested[i]) CGDisplayModeRelease(requested[i]);
    if (!valid) return NO;
    if (changed) PulsarSettle();
    if (!PulsarLayoutMatches(layout, owned, YES)) return NO;

    CGDisplayModeRef mode = PulsarFreshMode(owned, NULL, pixelWidth / scale, pixelHeight / scale, pixelWidth, pixelHeight);
    if (!mode) return NO;
    valid = PulsarLayoutMatches(layout, owned, YES) && CGBeginDisplayConfiguration(&config) == kCGErrorSuccess;
    if (valid) {
        error = CGConfigureDisplayWithDisplayMode(config, owned, mode, NULL);
        if (error == kCGErrorSuccess) error = CGConfigureDisplayOrigin(config, owned, (int32_t)left, (int32_t)top);
        if (error != kCGErrorSuccess) { CGCancelDisplayConfiguration(config); valid = NO; }
        else valid = CGCompleteDisplayConfiguration(config, kCGConfigureForSession) == kCGErrorSuccess;
    }
    CGDisplayModeRelease(mode);
    if (!valid) return NO;
    PulsarSettle();
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(owned);
    valid = PulsarLayoutMatches(layout, owned, YES) && CGDisplayIsActive(owned)
        && !CGDisplayIsInMirrorSet(owned) && !CGDisplayMirrorsDisplay(owned) && current
        && CGDisplayModeGetWidth(current) == pixelWidth / scale && CGDisplayModeGetHeight(current) == pixelHeight / scale
        && CGDisplayModeGetPixelWidth(current) == pixelWidth && CGDisplayModeGetPixelHeight(current) == pixelHeight;
    if (current) CGDisplayModeRelease(current);
    return valid;
}

NSObject * _Nullable PulsarCreateVirtualDisplay(unsigned int pixelWidth, unsigned int pixelHeight, unsigned int scale, uint32_t *outDisplayID) {
    if (outDisplayID) *outDisplayID = 0;
    if (!PulsarVirtualDisplayAPIAvailable()) return nil;
    if (pixelWidth < 640 || pixelWidth > 6016 || pixelHeight < 480 || pixelHeight > 3384) return nil;
    if (scale != 1 && scale != 2) return nil;

    PulsarPriorLayout prior = {0};
    if (!PulsarCaptureLayout(&prior)) { PulsarReleaseLayout(&prior); return nil; }
    @try {
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
    PulsarSettle();
    if (!PulsarPreserveLayout(&prior, displayID, pixelWidth, pixelHeight, scale)) return nil;
    if (outDisplayID) *outDisplayID = displayID;
    return display;
    } @finally { PulsarReleaseLayout(&prior); }
}

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

BOOL PulsarVirtualDisplayAPIAvailable(void);
NSObject * _Nullable PulsarCreateVirtualDisplay(unsigned int pixelWidth, unsigned int pixelHeight, unsigned int scale, uint32_t *outDisplayID) NS_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END

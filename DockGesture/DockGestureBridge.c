// Adapted from ThunderControl DockGesture/DockGestureBridge.c, which adapts the ISC-licensed ISS
// payload subset (joshuarli/iss 493b008f2ea8e9215877c39700e8ea3add800e97, see Vendor/LICENSE-ISC).
#include "DockGestureBridge.h"
#include <mach/mach_time.h>
#include <stdint.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
static const CGEventField kCGEventGestureSwipePositionX = 125;
static const CGEventField kCGEventGestureSwipePositionY = 126;
static const CGEventField kCGEventGestureSwipeMask = 115;
static const CGEventField kCGEventRawIOHIDPayload = 4205;
#include "Vendor/iss_payload.inc"

CGEventRef DGMakeDockSwipe(int motion, int phase, double progress, double vx, double vy) {
    if (motion != 1 && motion != 2) return NULL;
    if (phase != 1 && phase != 2 && phase != 4 && phase != 8) return NULL;
    if (!isfinite(progress) || fabs(progress) > 1 || !isfinite(vx) || fabs(vx) > 10000 || !isfinite(vy) || fabs(vy) > 10000) return NULL;
    CGEventRef e = CGEventCreate(NULL);
    if (!e) return NULL;
    CGEventSetIntegerValueField(e, 55, 30);
    CGEventSetIntegerValueField(e, 110, 23);
    CGEventSetIntegerValueField(e, 123, motion);
    CGEventSetIntegerValueField(e, 132, phase);
    CGEventSetIntegerValueField(e, 134, phase);
    CGEventSetDoubleValueField(e, 138, 3.0);
    CGEventSetDoubleValueField(e, 169, (double)mach_absolute_time());
    CGEventSetDoubleValueField(e, 125, 0.1);
    CGEventSetDoubleValueField(e, 124, progress);
    CGEventSetDoubleValueField(e, 129, vx);
    CGEventSetDoubleValueField(e, 130, vy);
    CGEventRef result = augment_dock_swipe_event(e);
    CFRelease(e);
    return result;
}

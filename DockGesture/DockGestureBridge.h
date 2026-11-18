#ifndef DOCK_GESTURE_BRIDGE_H
#define DOCK_GESTURE_BRIDGE_H
#include <ApplicationServices/ApplicationServices.h>
// Builds a synthetic DockSwipe event (motion 1 horizontal, 2 vertical; phase 1/2/4/8). Does not post.
CGEventRef _Nullable DGMakeDockSwipe(int motion, int phase, double progress, double vx, double vy) CF_RETURNS_RETAINED;
#endif

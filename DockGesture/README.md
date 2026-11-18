# DockSwipe bridge

`DockGestureBridge.c` builds the DockSwipe events (Spaces, Mission Control, App Exposé) that Dock consumes. It is adapted from ThunderControl's `DockGesture` bridge, which adapts the ISS payload subset in `Vendor/iss_payload.inc` (joshuarli/iss revision `493b008f2ea8e9215877c39700e8ea3add800e97`, ISC license in `Vendor/LICENSE-ISC`). It only builds events; the caller decides whether to post them. The descriptor carries motion, phase, progress and velocity, never finger count.

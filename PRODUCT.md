# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

Note: the shipped product is a native macOS AppKit app (Apple Silicon, macOS 14+). `web` is recorded only because the schema has no macOS value; design must follow macOS desktop conventions, not web or iOS patterns.

## Users
One person (the owner) controlling their own Macs. Typical scene: working on a MacBook away from home and driving a Mac mini at home or the office, for long working sessions under indoor light.

## Product Purpose
Pulsar shows another Mac's screen and forwards mouse, keyboard, shortcuts and trackpad gestures to it, on the same network or across networks. Success: open the app, pick a Mac from a list, be inside its screen in one action, and stay there without the app getting in the way.

## Positioning
A personal, Parsec-like remote desktop for the owner's own Macs that rides the owner's existing Tailscale network instead of a vendor account and relay service. No account, no cloud dashboard.

## Operating Context
- Host Mac runs Pulsar with sharing on; viewer Mac connects to it.
- Cross-network reach comes from Tailscale on both Macs (direct path measured around 8 ms in testing); LAN works directly.
- Same-account Macs connect from the device list over Tailscale (plain TCP on port 47700, host checks the peer owner with `tailscale whois`). Other Macs use a per-session pre-shared key carried in a connection code (TLS 1.2 ECDHE-PSK). One active viewer per host.
- The viewer auto-reconnects for up to 2 minutes after a network drop and keeps the last frame visible.
- macOS permissions gate features: Screen Recording (host), "Device control and data access" (macOS 27 name of Accessibility; host input, viewer system shortcuts), Input Monitoring (viewer shortcuts and gestures).

## Capabilities and Constraints
- Video: H.264 hardware encoding, up to 1920x1200, up to 30 fps, one display.
- Input: mouse, scroll, keyboard, app shortcuts, system shortcuts while the viewer is focused, pinch/rotate/smart magnify/swipe gestures (same macOS build required). 3/4-finger Dock gestures are not supported.
- One-tap connect works for Macs on the same Tailscale account; sharing can start automatically at launch. Disconnect, overlay and full-screen shortcuts are user-configurable and handled locally during a session.

## Brand Commitments
- Name: Pulsar (a pulsar is a neutron star emitting regular pulses), chosen by the user.
- Must not look like a copy of Parsec, must not look like a flashy gaming app, must feel native to macOS.

## Evidence on Hand
- Real measured numbers from testing: ~8 ms Tailscale direct ping between the owner's Macs, 1920x1080 at ~29 fps and ~100 KB/s on a mostly static screen.
- Real device names on the tailnet: mac-mini, macbookpro.
- No users, testimonials, or benchmarks beyond the above; do not invent any.

## Product Principles
- The remote screen is the product; chrome appears only when asked for.
- State is always legible: who you are connected to, how good the link is, what permission is missing.
- One action to connect, one action to leave.
- Behave like a Mac app: native controls, native shortcuts, no invented affordances.

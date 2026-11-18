---
name: Pulsar
description: Personal Mac-to-Mac remote desktop, read like a Swiss station departure board.
colors:
  ink: "#1E1E1E"
  secondary-text: "#62625F"
  dim: "#8E8E8B"
  sidebar: "#F2F2F0"
  content: "#FFFFFF"
  group: "#F6F6F4"
  rule: "#E3E3E0"
  navy: "#2D327D"
  signal-red: "#EB0000"
  ok-green: "#1E8E3E"
  board: "#1E1E1EEB"
typography:
  heading:
    fontFamily: "SF Pro (system), -apple-system"
    fontSize: "30px"
    fontWeight: 700
    lineHeight: 1.1
    letterSpacing: "-0.9px"
  section:
    fontFamily: "SF Pro (system), -apple-system"
    fontSize: "15px"
    fontWeight: 600
  body:
    fontFamily: "SF Pro (system), -apple-system"
    fontSize: "13px"
    fontWeight: 400
  caption:
    fontFamily: "SF Pro (system), -apple-system"
    fontSize: "11px"
    fontWeight: 400
rounded:
  row-select: "6px"
  group: "12px"
spacing:
  row: "44px"
  page-margin: "36px"
components:
  button-primary:
    backgroundColor: "{colors.navy}"
    textColor: "{colors.content}"
  button-destructive-text:
    textColor: "{colors.signal-red}"
  group-box:
    backgroundColor: "{colors.group}"
    rounded: "{rounded.group}"
  session-board:
    backgroundColor: "{colors.board}"
    textColor: "{colors.content}"
    height: "36px"
  edge-surface:
    backgroundColor: "#EBEBEB"
    depth: "26px"
    length: "140px"
---

# Design System: Pulsar

## Overview

**Creative North Star: "The departure board"**

Pulsar reads the owner's Macs the way a Swiss station board reads trains: one ruled row per machine, columns for route, delay and state, set in the system grotesk with tabular figures. The screen is white and calm; the world shows up in the board's rhythm and in a single red dot that, like the second hand of a station clock, means "live right now". Everything else is native macOS: sidebar, switches, popups, buttons.

During a session the remote screen owns the window. The only chrome is a one-line dark board along the top edge that appears on demand and fades away.

**Key Characteristics:**
- Ruled table, not thumbnail cards, for the device list.
- Flat colour only: no gradients, glass, glow or emoji.
- Colour carries state, never decoration.
- Native AppKit controls everywhere; grey sidebar selection instead of the system accent.

## Colors

A white and warm-grey ground with exactly two signal colours.

### Primary
- **SBB Navy** (#2D327D): the one primary action on a screen, the 연결 and 접속 buttons.

### Secondary
- **Signal Red** (#EB0000): live state only (this Mac or a listed Mac 공유 중, connected session dot) and disconnect actions (긴급 중지, 연결 종료).

### Neutral
- **Ink** (#1E1E1E): text and sidebar icons.
- **Secondary Text** (#62625F): captions and column headers; chosen to keep 4.5:1 on white and on the group fill.
- **Dim** (#8E8E8B): inactive rows (unsupported devices) only.
- **Sidebar** (#F2F2F0), **Content** (#FFFFFF), **Group** (#F6F6F4), **Rule** (#E3E3E0).
- **OK Green** (#1E8E3E): permission granted check icons.

### Named Rules
**The Station Clock Rule.** Red means live or stop. Nothing else on the screen is red.
**The One Train Rule.** One navy action per screen region.

## Typography

**Display Font:** SF Pro (system)
**Body Font:** SF Pro (system)

**Character:** One workhorse grotesk, weight and size steps only. Headings tightened to -0.03em, figures tabular.

## Elevation

None beyond the native window shadow. Groups are flat fills with 12px radius; tables use 1px rules.

## Components

- **Device board:** NSTableView, 44px rows, 1px rule under each row, semibold 12px grey headers, connect button at row end.
- **Grouped rows:** System Settings style groups on the 연결코드 and 설정 pages.
- **Session board:** 36px dark bar, red pulsing dot, peer name, live fps and Mbps, 전체 화면 and 연결 종료. Fades over 200ms ease-out; pulse 250ms; both off under Reduce Motion.
- **Edge surface (disabled in 0.11 by `EdgeSurface.enabled`; the 0.25 s push gate remains):** opaque grey (white 0.92, #EBEBEB) rubber band on the left or right outer edge of a screen while the pointer pushes out of it. Up to 26 pt deep and 140 pt along the edge, centred on the pointer and kept inside the screen. Depth follows f(u) = u*26*1.5 / (26 + 1.5u) on a damped spring; release returns with a 1.2x slower response and fades. A non-activating, click-through panel that never takes focus. Under Reduce Motion the spring is replaced by a 0.1 s ease, while the 0.25 s push threshold stays the same. Ported from ThunderControl.

## Do's and Don'ts
- Do keep the device list a ruled table.
- Do label unfinished features honestly; a disabled control says why in its tooltip ("상대 Mac에서 공유를 켜 주세요").
- Don't use the system accent blue for selection.
- Don't add thumbnails, gradients or neon to the device list.

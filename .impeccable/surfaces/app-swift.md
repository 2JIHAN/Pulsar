---
version: 1
slug: "app-swift"
primary_target: "App.swift"
related_targets: ["Permissions.swift"]
---

# Pulsar main window

Scope: the whole app window (device list, connection code, settings with permissions and shortcuts, live session). Mode: Operate. Native macOS AppKit. Build path: code-led (native app; the web comp-measure gates do not apply). Decision comp kept as critique reference: .impeccable/mocks/decision/assigned.png

## Direction contract
THESIS: My Macs read like a Swiss station departure board, and a red station-clock dot says a link is live. Refuses the dark thumbnail-card grid every remote desktop ships.
OWN-WORLD: White content, warm grey #F2F2F0 native sidebar, ink #1E1E1E, SBB navy #2D327D for the one primary action, signal red #EB0000 only for live state and disconnect. Flat colour, hairline rules, tabular figures, SF Pro bold headings with tight tracking. Native controls only.
STORY: Open, see which Mac is sharing and how good the path is, press 연결 once, work inside the remote screen undisturbed, leave with one shortcut.
FIRST VIEWPORT: Sidebar (컴퓨터, 연결코드, 설정, bottom "이 Mac 공유 중" red dot). Main: large "컴퓨터" heading; departure-board table 기기 | 경로 | 지연 | 상태 | 연결, navy button at row end; bottom strip "이 Mac" with 원격 입력 허용 toggle and three permission states plus 설정 열기.
FORM: Swiss railway signage (SBB), position 3 of the ordered list, seed key 6e60317c. Raises: flat colour only (zoo map), session owns the window with a one-line top board (vertical feed), colour only for state (lexicon), live-updating tabular readouts (variable font).
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

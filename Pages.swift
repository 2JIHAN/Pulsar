import AppKit

// Swiss railway signage: flat colour, hairline rules, colour only for state.
// Red is reserved for live state and disconnect; navy only for the primary connect action.
enum Palette {
    static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: alpha)
    }
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hex(dark) : hex(light) }
    }
    static let ink = dynamic(0x1E1E1E, 0xEDEDEB)
    // #62625F keeps 4.5:1 on white and on the grouped fill; system secondaryLabel does not.
    static let secondary = dynamic(0x62625F, 0xA6A6A3)
    static let dim = dynamic(0x8E8E8B, 0x6E6E6B)
    static let sidebar = dynamic(0xF2F2F0, 0x262624)
    static let content = dynamic(0xFFFFFF, 0x1C1C1B)
    static let group = dynamic(0xF6F6F4, 0x2A2A28)
    static let rule = dynamic(0xE3E3E0, 0x3A3A38)
    static let green = dynamic(0x1E8E3E, 0x32D74B)
    static let navy = hex(0x2D327D)
    static let red = hex(0xEB0000)
    static let board = hex(0x1E1E1E, 0.92)
}

func label(_ text: String, _ size: CGFloat = 13, _ weight: NSFont.Weight = .regular, _ color: NSColor = Palette.ink) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight); l.textColor = color; l.lineBreakMode = .byTruncatingTail
    return l
}
func heading(_ text: String) -> NSTextField {
    let l = label(text, 30, .bold)
    l.attributedStringValue = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: Palette.ink, .kern: -0.9])
    return l
}
func sectionTitle(_ text: String) -> NSTextField { label(text, 15, .semibold) }
func symbol(_ name: String, _ size: CGFloat = 12) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .medium))
}
func hstack(_ views: [NSView], _ spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = .horizontal; s.spacing = spacing; s.alignment = .centerY; return s
}
func vstack(_ views: [NSView], _ spacing: CGFloat = 2) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = .vertical; s.spacing = spacing; s.alignment = .leading; return s
}
func spacer() -> NSView { let v = NSView(); v.setContentHuggingPriority(.init(1), for: .horizontal); return v }
func navyButton(_ title: String, _ target: AnyObject?, _ action: Selector?) -> NSButton {
    let b = NSButton(title: title, target: target, action: action); b.bezelColor = Palette.navy; return b
}
func redTextButton(_ title: String, _ target: AnyObject?, _ action: Selector?) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: Palette.red, .font: NSFont.systemFont(ofSize: 13, weight: .medium)])
    return b
}

class FillView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    var radius: CGFloat
    init(_ color: NSColor, radius: CGFloat = 0) { self.color = color; self.radius = radius; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill() }
}
final class FlippedView: NSView { override var isFlipped: Bool { true } }
func rule() -> NSView { let r = FillView(Palette.rule); r.heightAnchor.constraint(equalToConstant: 1).isActive = true; return r }

final class Dot: NSView {
    var color = Palette.dim { didSet { needsDisplay = true } }
    init(_ size: CGFloat = 8) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: size).isActive = true; heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); NSBezierPath(ovalIn: bounds).fill() }
    // A 250 ms ease-out dip once a second, like the station clock's second hand. Off with Reduce Motion.
    func pulse(_ on: Bool) {
        layer?.removeAnimation(forKey: "pulse")
        guard on, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0.35; fade.duration = 0.25; fade.autoreverses = true
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let group = CAAnimationGroup(); group.animations = [fade]; group.duration = 1; group.repeatCount = .infinity
        layer?.add(group, forKey: "pulse")
    }
}

final class Keycap: NSView {
    let text: String
    init(_ text: String) { self.text = text; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    var attributes: [NSAttributedString.Key: Any] { [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Palette.ink] }
    override var intrinsicContentSize: NSSize { NSSize(width: max(22, (text as NSString).size(withAttributes: attributes).width + 12), height: 22) }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        Palette.content.setFill(); path.fill(); Palette.rule.setStroke(); path.stroke()
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

// System Settings style grouped rows: one fill, no border, hairlines between rows.
func group(_ rows: [NSView]) -> NSView {
    let box = FillView(Palette.group, radius: 12)
    var views = [NSView]()
    for (i, r) in rows.enumerated() {
        if i > 0 { let line = rule(); views.append(line) }
        views.append(r)
    }
    let stack = vstack(views, 0)
    stack.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(stack)
    for v in views where !(v is FillView) { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: box.leadingAnchor), stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                                 stack.topAnchor.constraint(equalTo: box.topAnchor), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor)])
    for v in views where v is FillView { v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16).isActive = true; v.trailingAnchor.constraint(equalTo: box.trailingAnchor).isActive = true }
    return box
}
func settingRow(_ title: String, _ sub: String? = nil, _ accessories: [NSView]) -> NSStackView {
    let col = vstack([label(title)])
    if let sub { let s = label(sub, 11, .regular, Palette.secondary); s.setContentCompressionResistancePriority(.init(749), for: .horizontal); col.addArrangedSubview(s) }
    col.setContentHuggingPriority(.init(1), for: .horizontal)
    col.setContentCompressionResistancePriority(.init(749), for: .horizontal)
    let row = hstack([col, spacer()] + accessories, 12)
    row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
    row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    return row
}
// A vertical page that scrolls; content starts below the transparent title bar.
func scrollPage(_ views: [NSView]) -> NSScrollView {
    let stack = vstack(views, 8)
    for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -80).isActive = true }
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 40, bottom: 32, right: 40)
    let doc = FlippedView(); stack.translatesAutoresizingMaskIntoConstraints = false; doc.addSubview(stack)
    let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
    doc.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = doc
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                                 stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
                                 doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                                 doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
    return scroll
}
func gap(_ height: CGFloat) -> NSView { let v = NSView(); v.heightAnchor.constraint(equalToConstant: height).isActive = true; return v }

// MARK: Tailscale devices

struct TailscaleDevice: Equatable {
    enum State: Equatable { case thisMac, online, offline, unsupported }
    let name: String, os: String, online: Bool, ips: [String], isSelf: Bool, direct: Bool
    var state: State { isSelf ? .thisMac : os != "macOS" ? .unsupported : online ? .online : .offline }
    var stateText: String {
        switch state { case .thisMac: return "이 Mac"; case .online: return "온라인"; case .offline: return "오프라인"; case .unsupported: return "지원 안 함" }
    }
    // CurAddr is only set while a direct UDP path exists; otherwise traffic may go through DERP or be idle.
    var path: String { isSelf || !online ? "—" : direct ? "Tailscale 직접" : "Tailscale" }

    private struct Node: Decodable { var HostName: String?; var OS: String?; var Online: Bool?; var TailscaleIPs: [String]?; var CurAddr: String? }
    private struct Status: Decodable {
        var BackendState: String?; var me: Node?; var Peer: [String: Node]?
        enum CodingKeys: String, CodingKey { case BackendState, me = "Self", Peer }
    }
    // nil means Tailscale is not usable (bad output, logged out or stopped), which the list explains.
    static func parse(_ data: Data) -> [TailscaleDevice]? {
        guard let s = try? JSONDecoder().decode(Status.self, from: data), s.BackendState == "Running" else { return nil }
        func device(_ n: Node, isSelf: Bool) -> TailscaleDevice {
            TailscaleDevice(name: (n.HostName ?? "이름 없음").replacingOccurrences(of: "\u{00A0}", with: " "), os: n.OS ?? "",
                            online: isSelf || (n.Online ?? false), ips: n.TailscaleIPs ?? [], isSelf: isSelf, direct: !(n.CurAddr ?? "").isEmpty)
        }
        let order: [State] = [.thisMac, .online, .offline, .unsupported]
        let all = (s.me.map { [device($0, isSelf: true)] } ?? []) + (s.Peer ?? [:]).values.map { device($0, isSelf: false) }
        return all.sorted { a, b in
            let x = order.firstIndex(of: a.state)!, y = order.firstIndex(of: b.state)!
            return x != y ? x < y : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    static let cli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    static func fetch(_ done: @escaping ([TailscaleDevice]?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var result: [TailscaleDevice]?
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: cli); p.arguments = ["status", "--json"]
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            if FileManager.default.isExecutableFile(atPath: cli), (try? p.run()) != nil {
                let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: stop)
                let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); stop.cancel()
                if p.terminationStatus == 0 { result = parse(data) }
            }
            DispatchQueue.main.async { done(result) }
        }
    }
}

// MARK: Shortcuts (recorded and saved; behaviour is wired in a later version)

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    var key: String
    static let mask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    var caps: [String] {
        let m = NSEvent.ModifierFlags(rawValue: modifiers)
        return [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { m.contains($0.0) }.map(\.1) + [key]
    }
    // Requires Control, Option or Command so a plain letter can never become a session shortcut.
    static func from(_ e: NSEvent) -> Shortcut? {
        let m = e.modifierFlags.intersection(mask)
        guard !m.intersection([.control, .option, .command]).isEmpty else { return nil }
        let names: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let chars = e.charactersIgnoringModifiers?.uppercased() ?? ""
        let key = names[e.keyCode] ?? (chars.unicodeScalars.allSatisfy { $0.value > 32 && $0.value != 127 } && !chars.isEmpty ? chars : "키 \(e.keyCode)")
        return Shortcut(keyCode: e.keyCode, modifiers: m.rawValue, key: key)
    }
}
enum ShortcutAction: String, CaseIterable {
    case disconnect, overlay, fullScreen
    var title: String { switch self { case .disconnect: return "연결 종료"; case .overlay: return "오버레이 메뉴"; case .fullScreen: return "전체 화면" } }
    var fallback: Shortcut {
        let m = NSEvent.ModifierFlags([.control, .option, .command]).rawValue
        switch self {
        case .disconnect: return Shortcut(keyCode: 2, modifiers: m, key: "D")
        case .overlay: return Shortcut(keyCode: 31, modifiers: m, key: "O")
        case .fullScreen: return Shortcut(keyCode: 3, modifiers: m, key: "F")
        }
    }
    var defaultsKey: String { "shortcut." + rawValue }
    func load(_ d: UserDefaults = .standard) -> Shortcut {
        d.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? fallback
    }
    func save(_ s: Shortcut, _ d: UserDefaults = .standard) { d.set(try? JSONEncoder().encode(s), forKey: defaultsKey) }
    static let systemKey = "sendSystemShortcuts"
    static func sendsSystem(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: systemKey) as? Bool ?? true }
}

// MARK: Sidebar

// Grey selection instead of the system accent: in this world colour is reserved for live state.
final class SidebarRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.08) }.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    override var isEmphasized: Bool { get { false } set {} }
}
final class SidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let items = [("컴퓨터", "desktopcomputer"), ("연결코드", "chevron.left.forwardslash.chevron.right"), ("설정", "gearshape")]
    let table = NSTableView()
    let hostDot = Dot()
    let hostLabel = label("공유 꺼짐", 12, .regular, Palette.secondary)
    let hostButton: NSButton
    var onSelect: ((Int) -> Void)?
    init(hostButton: NSButton) { self.hostButton = hostButton; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let root = FillView(Palette.sidebar)
        table.style = .sourceList; table.selectionHighlightStyle = .regular; table.headerView = nil; table.rowHeight = 32; table.backgroundColor = .clear
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.dataSource = self; table.delegate = self
        let scroll = NSScrollView(); scroll.documentView = table; scroll.drawsBackground = false
        let bottom = vstack([hstack([hostDot, hostLabel], 8), hostButton], 10); bottom.alignment = .leading
        for v in [scroll, bottom] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), bottom.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
        view = root
        table.selectRowIndexes([0], byExtendingSelection: false)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(), image = NSImageView(image: symbol(items[row].1, 14) ?? NSImage()), text = label(items[row].0)
        image.contentTintColor = Palette.ink
        cell.imageView = image; cell.textField = text
        let s = hstack([image, text], 8); s.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(s)
        image.widthAnchor.constraint(equalToConstant: 20).isActive = true
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), s.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarRow() }
    func tableViewSelectionDidChange(_ notification: Notification) { if table.selectedRow >= 0 { onSelect?(table.selectedRow) } }
    func select(_ page: Int) { if table.selectedRow != page { table.selectRowIndexes([page], byExtendingSelection: false) } }
    func setHosting(_ on: Bool) {
        hostDot.color = on ? Palette.red : Palette.dim
        hostLabel.stringValue = on ? "이 Mac 공유 중" : "공유 꺼짐"; hostLabel.textColor = on ? Palette.ink : Palette.secondary
    }
}

// MARK: 컴퓨터 page

final class BoardHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Palette.content.setFill(); cellFrame.fill()
        Palette.rule.setFill(); NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        let s = NSAttributedString(string: stringValue, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Palette.secondary])
        s.draw(at: NSPoint(x: cellFrame.minX, y: cellFrame.midY - s.size().height / 2))
    }
}
final class BoardRow: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) { Palette.rule.setFill(); NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill() }
}

final class ComputersPage: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let scroll = NSScrollView()
    let emptyTitle = label("Tailscale 기기를 확인하는 중…", 15, .semibold)
    let emptyBody = NSTextField(wrappingLabelWithString: "")
    let emptyButton = NSButton(title: "연결코드로 접속", target: nil, action: nil)
    let permIcons = Permission.all.map { _ in NSImageView() }
    let permLabels = Permission.all.map { _ in label("", 12) }
    var devices = [TailscaleDevice]()
    var hosting = false { didSet { if hosting != oldValue { table.reloadData() } } }
    var onConnect: ((TailscaleDevice) -> Void)?
    var onCodePage: (() -> Void)?
    var onSettings: (() -> Void)?

    init(allow: NSSwitch) {
        super.init(frame: .zero)
        let codeButton = NSButton(title: "연결코드로 접속", target: self, action: #selector(codePage))
        let head = hstack([heading("컴퓨터"), spacer(), codeButton], 12)
        let columns: [(String, String, CGFloat)] = [("device", "기기", 260), ("path", "경로", 150), ("latency", "지연", 80), ("state", "상태", 130), ("action", "", 96)]
        for (id, title, width) in columns {
            let c = NSTableColumn(identifier: .init(id)); c.headerCell = BoardHeaderCell(textCell: title); c.width = width; c.minWidth = id == "action" ? 96 : 60
            c.resizingMask = id == "device" ? [.autoresizingMask] : []
            table.addTableColumn(c)
        }
        table.style = .plain; table.rowHeight = 52; table.intercellSpacing = .zero; table.backgroundColor = .clear
        table.selectionHighlightStyle = .none; table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 34))
        table.dataSource = self; table.delegate = self
        scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        emptyBody.font = .systemFont(ofSize: 13); emptyBody.textColor = Palette.secondary; emptyBody.preferredMaxLayoutWidth = 460
        emptyButton.target = self; emptyButton.action = #selector(codePage)
        let empty = vstack([emptyTitle, emptyBody, gap(4), emptyButton], 8)
        emptyButton.isHidden = true

        let allowRow = hstack([allow, label("원격 입력 허용")], 8)
        var strip: [NSView] = [label("이 Mac", 15, .bold), allowRow, separator()]
        for (icon, text) in zip(permIcons, permLabels) { text.setContentCompressionResistancePriority(.init(749), for: .horizontal); strip.append(hstack([icon, text], 4)) }
        strip += [spacer(), NSButton(title: "설정 열기", target: self, action: #selector(settings))]
        let bottom = hstack(strip, 16)
        let line = rule()
        for v in [head, scroll, empty, line, bottom] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40), head.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 24),
            scroll.leadingAnchor.constraint(equalTo: head.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -12),
            empty.leadingAnchor.constraint(equalTo: head.leadingAnchor), empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 56),
            line.leadingAnchor.constraint(equalTo: head.leadingAnchor), line.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: head.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 60), bottom.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        update(devices: nil, loading: true)
        refreshPermissions()
    }
    required init?(coder: NSCoder) { nil }
    func separator() -> NSView { let v = FillView(Palette.rule); v.widthAnchor.constraint(equalToConstant: 1).isActive = true; v.heightAnchor.constraint(equalToConstant: 20).isActive = true; return v }

    func update(devices found: [TailscaleDevice]?, loading: Bool = false) {
        devices = found ?? []
        let empty = devices.isEmpty
        emptyTitle.superview?.isHidden = !empty
        emptyButton.isHidden = loading
        if loading { emptyTitle.stringValue = "Tailscale 기기를 확인하는 중…"; emptyBody.stringValue = "" }
        else if found == nil {
            emptyTitle.stringValue = "Tailscale 기기를 불러올 수 없습니다"
            emptyBody.stringValue = "Pulsar는 같은 Tailscale 네트워크의 Mac을 이 목록에 보여 줍니다. Tailscale 앱을 설치하고 로그인해 연결하면 10초 안에 나타납니다. 연결코드로는 지금도 접속할 수 있습니다."
        } else { emptyTitle.stringValue = "Tailscale 네트워크에 기기가 없습니다"; emptyBody.stringValue = "다른 Mac에서 같은 계정으로 Tailscale에 로그인하면 여기에 나타납니다." }
        table.reloadData()
    }
    func refreshPermissions() {
        for (i, p) in Permission.all.enumerated() { p.show(icon: permIcons[i], text: permLabels[i], prefix: p.title + " ") }
    }
    @objc func codePage() { onCodePage?() }
    @objc func settings() { onSettings?() }
    @objc func connect(_ sender: NSButton) { if devices.indices.contains(sender.tag) { onConnect?(devices[sender.tag]) } }

    func numberOfRows(in tableView: NSTableView) -> Int { devices.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { BoardRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let d = devices[row], inactive = d.state == .unsupported || d.state == .offline
        let color = inactive ? Palette.dim : Palette.ink
        var views: [NSView]
        switch tableColumn?.identifier.rawValue {
        case "device": views = [label(d.name, 15, .semibold, color)]
        case "path": views = [label(d.path, 13, .regular, color)]
        case "latency":
            let l = label("—", 13, .regular, color); l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular); views = [l]
        case "state":
            let dot = Dot()
            switch d.state {
            case .thisMac: dot.color = hosting ? Palette.red : Palette.dim; views = [dot, label(hosting ? "이 Mac 공유 중" : "이 Mac", 13, .regular, Palette.ink)]
            case .online: dot.color = Palette.ink; views = [dot, label(d.stateText)]
            case .offline: views = [dot, label(d.stateText, 13, .regular, Palette.dim)]
            case .unsupported: views = [label(d.stateText, 13, .regular, Palette.dim)]
            }
        default:
            guard d.state == .online || d.state == .offline else { return nil }
            let b = d.state == .online ? navyButton("연결", self, #selector(connect(_:))) : NSButton(title: "연결", target: nil, action: nil)
            b.tag = row; b.isEnabled = d.state == .online
            b.widthAnchor.constraint(equalToConstant: 80).isActive = true
            views = [b]
        }
        let cell = NSView(), s = hstack(views, 8)
        s.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(s)
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo: cell.leadingAnchor), s.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                                     s.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        if d.ips.first != nil { cell.toolTip = d.ips.joined(separator: "\n") }
        return cell
    }
}

extension Permission {
    func show(icon: NSImageView, text: NSTextField, prefix: String) {
        let ok = granted()
        icon.image = symbol(ok ? "checkmark.circle.fill" : "xmark.circle.fill")
        icon.contentTintColor = ok ? Palette.green : Palette.red
        text.stringValue = prefix + (ok ? grantedText : "허용 안 됨")
    }
}

// MARK: 설정 page

final class ShortcutRecorder: NSObject {
    let action: ShortcutAction
    let caps = hstack([], 4)
    let button = NSButton(title: "변경", target: nil, action: nil)
    var monitor: Any?
    var onStart: ((ShortcutRecorder) -> Void)?
    init(_ action: ShortcutAction) {
        self.action = action; super.init()
        button.target = self; button.action = #selector(toggle)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        showCaps()
    }
    func showCaps() { caps.setViews(action.load().caps.map { Keycap($0) }, in: .leading) }
    @objc func toggle() { monitor == nil ? start() : stop() }
    func start() {
        onStart?(self)
        button.title = "키를 누르세요…"
        // Swallows key events while recording so the combination does not trigger menus.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53 && e.modifierFlags.intersection(Shortcut.mask).isEmpty { self.stop(); return nil }
            if let s = Shortcut.from(e) { self.action.save(s); self.stop() } else { NSSound.beep() }
            return nil
        }
    }
    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil; button.title = "변경"; showCaps()
    }
}

final class SettingsPage: NSObject {
    var view: NSView!
    let permIcons = Permission.all.map { _ in NSImageView() }
    let permLabels = Permission.all.map { _ in label("", 12, .regular, Palette.secondary) }
    let recorders = ShortcutAction.allCases.map(ShortcutRecorder.init)
    let system = NSSwitch()
    override init() {
        super.init()
        var permRows = [NSView]()
        for (i, p) in Permission.all.enumerated() {
            let b = NSButton(title: "설정 열기", target: self, action: #selector(open(_:))); b.tag = i
            let title = hstack([label(p.title), permIcons[i], permLabels[i]], 6)
            let use = label(p.use, 11, .regular, Palette.secondary); use.setContentCompressionResistancePriority(.init(749), for: .horizontal)
            let col = vstack([title, use]); col.setContentHuggingPriority(.init(1), for: .horizontal); col.setContentCompressionResistancePriority(.init(749), for: .horizontal)
            let row = hstack([col, spacer(), b], 12); row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
            permRows.append(row)
        }
        let note = label("권한을 바꾼 뒤에는 Pulsar를 다시 열어야 적용될 수 있습니다. 화면 기록은 다시 열기 전까지 허용 안 됨으로 보일 수 있습니다.", 11, .regular, Palette.secondary)
        note.lineBreakMode = .byWordWrapping; note.maximumNumberOfLines = 0
        var keyRows = [NSView]()
        for r in recorders {
            r.onStart = { [weak self] current in self?.recorders.filter { $0 !== current }.forEach { $0.stop() } }
            keyRows.append(settingRow(r.action.title, "다음 버전에서 동작", [r.caps, r.button]))
        }
        system.state = ShortcutAction.sendsSystem() ? .on : .off
        system.target = self; system.action = #selector(systemChanged)
        keyRows.append(settingRow("시스템 단축키를 원격으로 보내기", "설정만 저장됩니다. 지금은 권한이 있으면 항상 보냅니다.", [system]))
        let readout = { (text: String) -> NSTextField in let l = label(text, 13, .regular, Palette.secondary); l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular); return l }
        let info = Bundle.main.infoDictionary
        let version = label("Pulsar \(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))", 11, .regular, Palette.secondary)
        view = scrollPage([
            heading("설정"), gap(16),
            sectionTitle("권한"), group(permRows), note, gap(20),
            sectionTitle("단축키"), group(keyRows), gap(20),
            sectionTitle("화면"), group([settingRow("해상도", nil, [readout("최대 1920×1200")]), settingRow("프레임", nil, [readout("최대 30fps")])]),
            gap(12), version,
        ])
        refreshPermissions()
    }
    func refreshPermissions() { for (i, p) in Permission.all.enumerated() { p.show(icon: permIcons[i], text: permLabels[i], prefix: "") } }
    func stopRecording() { recorders.forEach { $0.stop() } }
    @objc func open(_ sender: NSButton) { Permission.all[sender.tag].openSettings() }
    @objc func systemChanged() { UserDefaults.standard.set(system.state == .on, forKey: ShortcutAction.systemKey) }
}

// MARK: Session

// The remote screen owns the content area. A one-line ink board slides in from the top edge.
final class SessionView: NSView {
    let viewer: Viewer
    let board = FillView(Palette.board)
    let dot = Dot()
    let peer = label("", 13, .semibold, .white)
    let metrics = label("", 13, .regular, NSColor(white: 1, alpha: 0.72))
    let fullScreen = NSButton(title: "전체 화면", target: nil, action: nil)
    let leave = NSButton(title: "연결 종료", target: nil, action: nil)
    var pinned = false
    var shown = false
    var holdUntil = Date.distantPast
    var pointerNearTop = false
    init(viewer: Viewer) {
        self.viewer = viewer
        super.init(frame: .zero)
        metrics.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        leave.bezelColor = Palette.red
        board.appearance = NSAppearance(named: .darkAqua)
        let row = hstack([dot, peer, metrics, spacer(), fullScreen, leave], 10)
        row.setCustomSpacing(16, after: metrics)
        for v in [viewer, board] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        row.translatesAutoresizingMaskIntoConstraints = false; board.addSubview(row)
        NSLayoutConstraint.activate([
            viewer.leadingAnchor.constraint(equalTo: leadingAnchor), viewer.trailingAnchor.constraint(equalTo: trailingAnchor), viewer.bottomAnchor.constraint(equalTo: bottomAnchor),
            board.leadingAnchor.constraint(equalTo: leadingAnchor), board.trailingAnchor.constraint(equalTo: trailingAnchor),
            board.topAnchor.constraint(equalTo: viewer.topAnchor), board.heightAnchor.constraint(equalToConstant: 36),
            row.leadingAnchor.constraint(equalTo: board.leadingAnchor, constant: 14), row.trailingAnchor.constraint(equalTo: board.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: board.centerYAnchor),
        ])
        board.isHidden = true; board.alphaValue = 0
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) { NSColor.black.setFill(); bounds.fill() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    // The board appears when the pointer touches the top 6 pt of the remote screen and leaves once it moves below the board.
    override func mouseMoved(with event: NSEvent) {
        let y = viewer.convert(event.locationInWindow, from: nil).y
        pointerNearTop = y <= 44
        if y <= 6 { setBoard(true) } else if !pointerNearTop { hideIfIdle() }
    }
    override func mouseExited(with event: NSEvent) { pointerNearTop = false; hideIfIdle() }
    func hideIfIdle() { if shown && !pinned && Date() >= holdUntil && !pointerNearTop { setBoard(false) } }
    func flash(_ seconds: TimeInterval) {
        holdUntil = Date() + seconds; setBoard(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in self?.hideIfIdle() }
    }
    func setBoard(_ show: Bool) {
        guard show != shown else { return }
        shown = show
        if show { board.isHidden = false }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { board.alphaValue = show ? 1 : 0; board.isHidden = !show; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            board.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in guard let self, !self.shown else { return }; self.board.isHidden = true })
    }
    func live(peer name: String, metrics text: String) {
        if pinned { pinned = false; flash(3) }
        dot.color = Palette.red; dot.pulse(true)
        peer.stringValue = name; metrics.stringValue = text
    }
    func reconnecting(_ attempt: Int, peer name: String) {
        pinned = true; setBoard(true)
        dot.color = Palette.dim; dot.pulse(false)
        peer.stringValue = "재연결 중… (\(attempt)회)"; metrics.stringValue = name
    }
}

final class ContentController: NSViewController {
    var pages = [NSView]()
    var session: SessionView!
    private(set) var current = 0
    override func loadView() { view = FillView(Palette.content) }
    func setup(pages: [NSView], session: SessionView) {
        self.pages = pages; self.session = session
        for v in pages + [session] {
            v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v)
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: view.leadingAnchor), v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                                         v.topAnchor.constraint(equalTo: view.topAnchor), v.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        }
        session.isHidden = true
        show(0)
    }
    func show(_ page: Int) { current = page; for (i, v) in pages.enumerated() { v.isHidden = i != page } }
}

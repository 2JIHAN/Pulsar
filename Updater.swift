import AppKit
import Security

// Auto update from GitHub releases. Pulsar ships only prereleases, so /releases/latest would miss them.
enum AutoUpdate {
    static let key = "PulsarAutoUpdate"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static let releasesURL = URL(string: "https://api.github.com/repos/2JIHAN/Pulsar/releases?per_page=10")!
    // Same team and bundle id keep macOS privacy permissions across the swap; anything else is refused.
    static let requirement = "anchor apple generic and identifier \"com.tamcut.Pulsar\" and certificate leaf[subject.OU] = \"9SADL7543X\""

    struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String; let draft: Bool; let assets: [Asset]
    }
    static func isNewer(_ a: String, than b: String) -> Bool { a.compare(b, options: .numeric) == .orderedDescending }
    static func newest(_ releases: [Release], current: String) -> (version: String, zip: URL)? {
        releases.filter { !$0.draft }.compactMap { r -> (version: String, zip: URL)? in
            let v = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
            guard isNewer(v, than: current), let a = r.assets.first(where: { $0.name == "Pulsar-\(v)-macOS-arm64.zip" }) else { return nil }
            return (v, a.browser_download_url)
        }.max { isNewer($1.version, than: $0.version) }
    }
    // Unzips and checks signature, team and version. Returns the verified app.
    static func prepare(zip: URL, version: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PulsarUpdate-\(UUID().uuidString)")
        let ditto = Process(); ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); ditto.arguments = ["-x", "-k", zip.path, dir.path]
        guard (try? ditto.run()) != nil else { return nil }
        ditto.waitUntilExit()
        let app = dir.appendingPathComponent("Pulsar.app")
        var code: SecStaticCode?, req: SecRequirement?
        guard ditto.terminationStatus == 0,
              Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String == version,
              SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), req) == errSecSuccess
        else { try? FileManager.default.removeItem(at: dir); return nil }
        return app
    }
}

// Checks at launch and hourly; installs only when no one is connected in either direction.
final class Updater {
    var idle: () -> Bool = { true }
    private var timer: Timer?
    private var busy = false
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.check() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check() }
    }
    func check() {
        guard AutoUpdate.enabled, !busy, idle(), let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }
        busy = true
        var req = URLRequest(url: AutoUpdate.releasesURL); req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data, let list = try? JSONDecoder().decode([AutoUpdate.Release].self, from: data),
                  let new = AutoUpdate.newest(list, current: current) else { DispatchQueue.main.async { self?.busy = false }; return }
            URLSession.shared.downloadTask(with: new.zip) { file, _, _ in
                let app = file.flatMap { AutoUpdate.prepare(zip: $0, version: new.version) }
                DispatchQueue.main.async { self?.busy = false; if let app { self?.install(app) } }
            }.resume()
        }.resume()
    }
    // A detached shell swaps the bundle after this process exits, restores the old one on failure, then reopens.
    private func install(_ app: URL) {
        guard AutoUpdate.enabled, idle() else { return }   // re-checked at the next hourly check
        let dest = Bundle.main.bundlePath, old = app.deletingLastPathComponent().appendingPathComponent("old.app").path
        let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; mv \"$2\" \"$3\" && { /usr/bin/ditto \"$1\" \"$2\" || { rm -rf \"$2\"; mv \"$3\" \"$2\"; }; }; open \"$2\""
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", script, "sh", app.path, dest, old]
        guard (try? p.run()) != nil else { return }
        NSApp.terminate(nil)
    }
}

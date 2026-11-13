import AppKit
if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
} else {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.run()
}

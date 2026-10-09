import AppKit
import LaunchIconCore

@MainActor
final class StoreSpikeAppDelegate: NSObject, NSApplicationDelegate {
    private let hotKeyService = CarbonGlobalHotKeyService()
    private var windowController: StoreSpikeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController = StoreSpikeWindowController()
        windowController?.showWindow(nil)
        switch hotKeyService.registerOptionSpace(onPressed: { [weak self] in
            DispatchQueue.main.async { self?.windowController?.toggleVisibility() }
        }) {
        case .success:
            windowController?.setHotKeyResult("registered")
        case let .failure(error):
            windowController?.setHotKeyResult("failed: \(error)")
        }
        windowController?.runCapabilityProbe()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyService.unregister()
    }
}

@main
@MainActor
enum StoreSpikeMain {
    private static let appDelegate = StoreSpikeAppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.delegate = appDelegate
        application.run()
    }
}

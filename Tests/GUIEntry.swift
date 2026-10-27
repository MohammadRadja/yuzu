#if YUZU_OWNED_GUI_BINARY
    import AppKit

    @MainActor
    private final class OwnedApplicationDelegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateCancel }
    }

    @main
    @MainActor
    struct OwnedGUIEntry {
        static func main() {
            if CommandLine.arguments.dropFirst().first == "--qa-shelf-reopen" {
                let runner = TestRunner(); RoadmapValidation.reopenedShelf(runner); runner.finish()
            }
            if ProcessInfo.processInfo.environment["YUZU_VOLUME_TESTS"] == "1" {
                Task { @MainActor in
                    let runner = TestRunner(); await RoadmapValidation.volumeLifecycle(runner); runner.finish()
                }
                dispatchMain()
            }
            guard ValidationRuntime.ownedGUI, ValidationRuntime.isolatedDefaults != nil else {
                fputs("Use scripts/check-gui.sh for isolated process-owned GUI validation\n", stderr); exit(2)
            }
            setbuf(stdout, nil)
            let app = NSApplication.shared
            let delegate = OwnedApplicationDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            ProcessInfo.processInfo.disableAutomaticTermination("Owned GUI integration tests")
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "User-requested GUI validation")
            Task(priority: .userInitiated) { @MainActor in
                let runner = TestRunner()
                await OwnedGUIValidation.register(runner)
                runner.finish()
            }
            withExtendedLifetime((delegate, activity)) { app.run() }
        }
    }
#endif

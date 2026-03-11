import SwiftUI

@main
struct CameraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 640, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 720)
        .commands {
            CommandGroup(after: .appSettings) {
                SettingsMenuContent()
            }
        }
    }
}

struct SettingsMenuContent: View {
    @AppStorage("imageFormat") private var format: String = "png"
    @AppStorage("exifCamera") private var exifCamera: Bool = true
    @AppStorage("exifLens") private var exifLens: Bool = true
    @AppStorage("exifLocation") private var exifLocation: Bool = true
    @AppStorage("exifDateTime") private var exifDateTime: Bool = true
    @AppStorage("exifSoftware") private var exifSoftware: Bool = true

    var body: some View {
        Menu("Image Format") {
            Button { format = "png" } label: {
                Text(format == "png" ? "✓ PNG" : "   PNG")
            }
            Button { format = "heic" } label: {
                Text(format == "heic" ? "✓ HEIC" : "   HEIC")
            }
        }

        Divider()

        Menu("EXIF Data") {
            Toggle("Camera Make & Model", isOn: $exifCamera)
            Toggle("Lens Info", isOn: $exifLens)
            Toggle("Location (GPS)", isOn: $exifLocation)
            Toggle("Date & Time", isOn: $exifDateTime)
            Toggle("Software", isOn: $exifSoftware)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

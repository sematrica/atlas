import SwiftUI

@main
struct AtlasApp: App {
    @State private var library = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(library: library)
                .frame(minWidth: 860, minHeight: 580)
                .onAppear { library.startMonitoring() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    library.stopMonitoring()
                }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Storage Location…") { Task { await library.chooseStorage() } }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(library.isBusy)
            }
        }
    }
}

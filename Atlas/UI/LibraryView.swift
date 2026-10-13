import SwiftUI
import AtlasCore

struct LibraryView: View {
    let model: LibraryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("wiki-atlas")
                        .font(.system(size: 32, weight: .medium, design: .serif))
                    Text("Keep Wikipedia on your Mac or an external drive. Your library stays where you choose.")
                        .font(.body).foregroundStyle(.secondary)
                }
                switch model.state {
                case .unconfigured:
                    storageCard {
                        Label("Start with a storage location", systemImage: "externaldrive.badge.plus")
                            .font(.title3.weight(.semibold))
                        Text("Choose or create a dedicated Sematrica folder. An external SSD gives your future encyclopedia room to grow.")
                            .foregroundStyle(.secondary)
                        chooseButton
                    }
                case .available(let snapshot):
                    storageCard {
                        HStack {
                            Label(snapshot.volumeName, systemImage: "externaldrive.fill").font(.title3.weight(.semibold))
                            Spacer()
                            Label(snapshot.isReadOnly ? "Read-only" : "Connected", systemImage: snapshot.isReadOnly ? "lock.fill" : "checkmark.circle.fill")
                                .foregroundStyle(snapshot.isReadOnly ? .orange : .green).font(.callout)
                        }
                        Text(snapshot.root.path).font(.callout.monospaced()).textSelection(.enabled)
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        HStack(spacing: 40) {
                            capacity("Available", bytes: snapshot.availableBytes)
                            capacity("Total storage", bytes: snapshot.totalBytes)
                        }
                        if let total = snapshot.totalBytes, total > 0, let available = snapshot.availableBytes {
                            ProgressView(value: min(max(Double(total - available) / Double(total), 0), 1))
                                .accessibilityLabel("Volume storage used")
                            Text("Storage figures apply to the entire volume.").font(.caption).foregroundStyle(.secondary)
                        }
                        if snapshot.isReadOnly {
                            Text("This library is accessible, but the volume does not allow changes.").font(.callout).foregroundStyle(.orange)
                        }
                        HStack { chooseButton; refreshButton }
                    }
                case .unavailable(let path, let volumeName, let reason):
                    storageCard {
                        Label(volumeName ?? "Library unavailable", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.title3.weight(.semibold))
                        Label("Disconnected or inaccessible", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                        if let path { Text(path).font(.callout.monospaced()).textSelection(.enabled) }
                        Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("Storage capacity is unavailable until the library reconnects.").font(.caption).foregroundStyle(.secondary)
                        HStack { refreshButton; chooseButton }
                    }
                }
                PackagesView(model: model.packages)
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .padding(40).frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem {
                if model.isBusy { ProgressView().controlSize(.small).accessibilityLabel("Checking library") }
            }
        }
    }

    private var chooseButton: some View {
        Button("Choose Storage Location…") { Task { await model.chooseStorage() } }
            .buttonStyle(.borderedProminent).disabled(model.isBusy)
    }

    private var refreshButton: some View {
        Button("Check Connection", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            .disabled(model.isBusy)
    }

    private func capacity(_ title: String, bytes: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable")
                .font(.title2.weight(.medium)).monospacedDigit()
        }
    }

    private func storageCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18, content: content)
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1))
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AtlasCore

struct PackagesView: View {
    @Bindable var model: PackageLibraryModel
    @State private var section="Available"
    @State private var deleting: PackageRecord?
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Text("Packages").font(.title2.weight(.medium))
                Spacer()
                if model.importing { ProgressView().controlSize(.small) }
                Button("Import ZIM File…",action:chooseZIM).disabled(!model.storageAvailable || model.importing)
                    .help("Add a .zim file you already have: one you made, or downloaded elsewhere")
            }
            Picker("Packages",selection:$section) {
                Text("Available").tag("Available")
                Text("Downloading (\(model.pending.count))").tag("Downloading")
                Text("Installed (\(model.installed.count))").tag("Installed")
            }.pickerStyle(.segmented)
            if let message=model.message {
                HStack(alignment:.top) {
                    Image(systemName:"exclamationmark.circle").foregroundStyle(.orange)
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer(); Button { model.message=nil } label: {Image(systemName:"xmark")}.buttonStyle(.plain)
                }
            }
            if !model.storageAvailable { Text("Choose or reconnect storage to download or open packages.").foregroundStyle(.secondary) }
            if section == "Available" {
                HStack {
                    Picker("Source",selection:$model.catalogSource) {
                        Text("Kiwix library").tag("Kiwix")
                        Text("Wikimedia archives").tag("Archives")
                    }.frame(maxWidth:260).disabled(model.loadingCatalog)
                    .onChange(of:model.catalogSource) { model.catalog=[]; model.language=model.catalogSource == "Kiwix" ? "eng" : "" }
                    if model.catalogSource == "Kiwix" {
                        Picker("Collection",selection:$model.collection) {
                            ForEach(model.collections) { collection in Text(collection.title).tag(collection.id) }
                        }.frame(maxWidth:280).disabled(model.loadingCatalog)
                        .onChange(of:model.collection) { if !model.catalog.isEmpty { model.catalog=[]; Task { await model.loadCatalog() } } }
                    }
                    if model.catalogSource == "Archives" { TextField("Project, e.g. enwiki",text:$model.dumpProject).textFieldStyle(.roundedBorder) }
                    Button(model.catalog.isEmpty ? "Load Catalog" : "Refresh Catalog") { Task { await model.loadCatalog() } }.disabled(model.loadingCatalog)
                    if model.loadingCatalog { ProgressView().controlSize(.small) }
                }
                if model.catalogSource == "Kiwix",let summary=model.collections.first(where:{$0.id == model.collection})?.summary,!summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                if !model.catalog.isEmpty {
                    Picker("Language",selection:$model.language) {
                        Text("All languages").tag("")
                        ForEach(model.languages,id:\.self) { code in Text("\(Locale.current.localizedString(forLanguageCode:code) ?? code) (\(code))").tag(code) }
                    }.frame(maxWidth:350)
                    Text("\(model.filteredCatalog.count) packages · smallest first · sizes from the official catalog")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVStack(alignment:.leading,spacing:0) {
                        ForEach(model.filteredCatalog) { package in
                            HStack(alignment:.top) {
                                packageSummary(package)
                                Spacer()
                                if model.records.contains(where:{$0.id == package.id}) { Text("In library").font(.caption).foregroundStyle(.secondary) }
                                else {
                                    Button("Download") { Task { await model.download(package); if model.message == nil { section="Downloading" } } }
                                        .disabled(!model.storageAvailable || model.busyPackages.contains(package.id))
                                }
                            }.padding(.vertical,14)
                            Divider()
                        }
                    }
                } else { Text("Load the official catalog to choose a package. Reading installed packages never needs the catalog.").foregroundStyle(.secondary) }
            } else {
                let rows=section == "Installed" ? model.installed : model.pending
                if rows.isEmpty { Text(section == "Installed" ? "No packages installed yet." : "No downloads in progress.").foregroundStyle(.secondary).padding(.vertical,15) }
                ForEach(rows) { record in
                    VStack(alignment:.leading,spacing:10) {
                        packageSummary(record.package)
                        HStack {
                            Text(stateLabel(record)).font(.callout.weight(.semibold))
                            Text("Verification: \(record.verification.rawValue)").font(.caption).foregroundStyle(.secondary)
                            if model.updateAvailable(record) { Text("Update available").font(.caption).foregroundStyle(.tint) }
                        }
                        if record.state == .downloading || record.state == .paused || record.state == .failed {
                            ProgressView(value:min(Double(record.receivedBytes)/Double(max(record.package.downloadBytes,1)),1))
                            Text(downloadStatus(record)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if record.state == .verifying {
                            if let fraction=model.progress[record.id]?.verificationFraction {
                                ProgressView("Verifying \(Int(fraction*100))%",value:fraction)
                            } else { ProgressView("Verifying package…").controlSize(.small) }
                        }
                        if let message=record.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        Text((model.rootPath.map {$0+"/"} ?? "Library: ")+record.relativePath)
                            .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            if record.state == .installed {
                                if record.package.format == .zim { Button("Open") { Task { await model.open(record) } }.buttonStyle(.borderedProminent) }
                                Button("Verify") { Task { await model.verify(record.id) } }
                            } else if record.package.isImported {
                                // An import can't pause or resume; it's cancelled or removed and imported again.
                            } else if record.state == .downloading || record.state == .verifying {
                                Button("Pause") { Task { await model.pause(record.id) } }
                            } else if record.state != .corrupted {
                                Button(record.state == .failed ? "Retry / Resume" : "Resume") { Task { await model.resume(record.id) } }
                            }
                            Button(deleteLabel(record),role:.destructive) { deleting=record }
                        }.disabled(!model.storageAvailable)
                    }.padding(.vertical,12)
                    Divider()
                }
            }
        }
        .confirmationDialog("Remove package and its downloaded files?",isPresented:Binding(get:{deleting != nil},set:{if !$0 {deleting=nil}}),titleVisibility:.visible) {
            if let record=deleting { Button("Remove \(record.package.name)",role:.destructive) { Task { await model.delete(record.id) }; deleting=nil } }
            Button("Keep",role:.cancel) { deleting=nil }
        } message: { Text("This removes only this package’s archive and partial download from the selected library. For an imported package, the original file you chose is kept.") }
    }
    private func stateLabel(_ record: PackageRecord) -> String {
        if record.state == .installed && record.package.format == .archive { return "Stored" }
        if record.package.isImported {
            switch record.state {
            case .downloading: return "Copying"
            case .failed: return "Import failed"
            default: break
            }
        }
        return record.state.rawValue.capitalized
    }
    private func deleteLabel(_ record: PackageRecord) -> String {
        if record.state == .installed || record.state == .corrupted { return "Delete…" }
        if record.package.isImported { return record.state == .failed ? "Remove…" : "Cancel Import…" }
        return "Cancel Download…"
    }
    /// Asks for a .zim file and imports it.
    private func chooseZIM() {
        let panel=NSOpenPanel()
        panel.title="Import a ZIM file"
        panel.message="Sematrica copies the file into your library, checks it and adds it to Installed."
        panel.prompt="Import"
        panel.canChooseFiles=true; panel.canChooseDirectories=false; panel.allowsMultipleSelection=false
        panel.allowedContentTypes=[UTType(filenameExtension:"zim") ?? .data]
        guard panel.runModal() == .OK,let url=panel.url else { return }
        Task { await model.importFile(url); if model.message == nil { section="Downloading" } }
    }
    private func packageSummary(_ package: WikipediaPackage) -> some View {
        VStack(alignment:.leading,spacing:5) {
            Text("\(package.language) · \(package.name)").font(.headline)
            Text("\(package.kind.label) · \(package.version) · \(ByteCountFormatter.string(fromByteCount:package.downloadBytes,countStyle:.file)) · \(package.format.rawValue.uppercased())")
                .font(.caption).foregroundStyle(.secondary)
            Text(package.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(package.capabilities).font(.caption.weight(.medium)).foregroundStyle(.tint)
        }
    }
    private func downloadStatus(_ record: PackageRecord) -> String {
        let downloaded=ByteCountFormatter.string(fromByteCount:record.receivedBytes,countStyle:.file)
        let verb=record.package.isImported ? "copied" : "saved"
        guard let speed=model.progress[record.id]?.bytesPerSecond,speed > 0,record.state == .downloading else { return "\(downloaded) \(verb)" }
        let rate=ByteCountFormatter.string(fromByteCount:Int64(speed),countStyle:.file)
        let seconds=max(0,Double(record.package.downloadBytes-record.receivedBytes)/speed)
        let eta=seconds < 60 ? "less than a minute" : "\(Int(seconds/60)) min"
        return "\(downloaded) · \(rate)/s · \(eta) remaining"
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AtlasCore

struct PackagesView: View {
    @Bindable var model: PackageLibraryModel
    private var section: String {
        get { model.packagesSection }
        nonmutating set { model.packagesSection = newValue }
    }
    @State private var deleting: PackageRecord?
    @State private var deletingMap: BuiltLinkMap?
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Text("Packages").font(.title2.weight(.medium))
                Spacer()
                if model.importing { ProgressView().controlSize(.small) }
                Button("Import ZIM File…",action:chooseZIM).disabled(!model.storageAvailable || model.importing)
                    .help("Add a .zim file you already have: one you made, or downloaded elsewhere")
            }
            Picker("Packages",selection:$model.packagesSection) {
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
                    if model.catalogSource == "Archives" {
                        TextField("Project, e.g. enwiki",text:$model.dumpProject).textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await model.loadCatalog() } }
                    }
                    Button(model.catalog.isEmpty ? "Load Catalog" : "Refresh Catalog") { Task { await model.loadCatalog() } }.disabled(model.loadingCatalog)
                    if model.loadingCatalog { ProgressView().controlSize(.small) }
                }
                if model.catalogSource == "Kiwix",let summary=model.collections.first(where:{$0.id == model.collection})?.summary,!summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                if model.catalogSource == "Archives" {
                    // Each Wikimedia catalog is one wiki, so its language is the project's.
                    Text("One wiki per catalog: type its project and press Return. enwiki is English, simplewiki Simple English, frwiki French, dewiki German, eswiki Spanish, jawiki Japanese, and so on.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                if !model.linkMapFiles.isEmpty { linkMapDownload }
                if !model.catalog.isEmpty {
                    HStack {
                        if model.catalogSource == "Kiwix" {
                            Picker("Language",selection:$model.language) {
                                Text("All languages").tag("")
                                ForEach(model.languages,id:\.self) { code in Text("\(Locale.current.localizedString(forLanguageCode:code) ?? code) (\(code))").tag(code) }
                            }.frame(maxWidth:350)
                        }
                        TextField(model.catalogSource == "Kiwix" ? "Filter, e.g. simple or nopic" : "Filter, e.g. pagelinks",text:$model.catalogFilter)
                            .textFieldStyle(.roundedBorder).frame(maxWidth:260)
                    }
                    if model.catalogSource == "Kiwix",model.language == "eng" {
                        Text("Simple English Wikipedia is listed under English: filter by “simple” to find it.").font(.caption).foregroundStyle(.secondary)
                    }
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
                if section == "Installed" && (!model.dumpSets.isEmpty || !model.linkMaps.isEmpty) { linkMapCard }
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
                        if let note=record.package.archiveNote { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
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
        .confirmationDialog("Delete this link map?",isPresented:Binding(get:{deletingMap != nil},set:{if !$0 {deletingMap=nil}}),titleVisibility:.visible) {
            if let map=deletingMap { Button("Delete \(map.manifest.project) \(map.manifest.readableDate)",role:.destructive) { Task { await model.deleteLinkMap(map) }; deletingMap=nil } }
            Button("Keep",role:.cancel) { deletingMap=nil }
        } message: { Text("Connect the dots goes back to reading articles, and category questions stop working, until you build it again from the table dumps.") }
        .task(id:section) { if section == "Installed" { await model.refreshLinkMaps() } }
    }

    // MARK: Link maps

    /// In the Wikimedia archives: download the tables a link map is built from.
    private var linkMapDownload: some View {
        let files=model.linkMapFiles
        let missing=files.filter { package in !model.records.contains(where:{$0.id == package.id}) }
        let bytes=missing.reduce(Int64(0)) { $0+$1.downloadBytes }
        return VStack(alignment:.leading,spacing:8) {
            Label("Link map",systemImage:"point.3.connected.trianglepath.dotted").font(.headline)
            Text("Wikipedia's own tables of every link and category. Built into a link map, they make Connect the dots exact and instant, answer “what links here” for every article, and let you ask about categories. Your ZIM package is still what you read.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                if missing.isEmpty {
                    Text("All \(files.count) files are in your library. Build the map under Installed.").font(.caption)
                } else {
                    Button("Download the Link Map Files (\(missing.count) · \(ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file)))") {
                        Task { await model.downloadLinkMapFiles(); if model.message == nil { section="Downloading" } }
                    }.disabled(!model.storageAvailable)
                }
                Spacer()
                Text(files.first.map {"\($0.version) dump"} ?? "").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).background(Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:8))
    }

    /// Under Installed: the downloaded dump tables, the build, and the maps already built.
    private var linkMapCard: some View {
        VStack(alignment:.leading,spacing:12) {
            Label("Link maps",systemImage:"point.3.connected.trianglepath.dotted").font(.headline)
            ForEach(model.dumpSets) { set in
                VStack(alignment:.leading,spacing:6) {
                    HStack {
                        Text("\(set.project) · \(set.readableDate) tables").font(.callout.weight(.medium))
                        Spacer()
                        if model.linkMapBuild?.id == set.id {
                            Button("Cancel") { model.cancelLinkMapBuild() }
                        } else if set.missing.isEmpty {
                            let built=model.linkMaps.contains { $0.manifest.project == set.project && $0.manifest.date == set.date }
                            Button(built ? "Rebuild" : "Build Link Map") { model.buildLinkMap(set) }
                                .buttonStyle(.borderedProminent).disabled(model.linkMapBuild != nil || !model.storageAvailable)
                        }
                    }
                    if let build=model.linkMapBuild,build.id == set.id {
                        ProgressView(value:build.progress?.overall ?? 0)
                        Text(build.progress.map {"Step \($0.step) of \($0.steps): \($0.stage) · \(Int($0.fraction*100))%"} ?? "Starting…")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Text("A large Wikipedia takes several minutes and a few GB of memory. You can keep reading meanwhile.").font(.caption2).foregroundStyle(.secondary)
                    } else if !set.missing.isEmpty {
                        Text("Still needed: \(set.missing.map {"\(set.project)-\(set.date)-\($0).sql.gz"}.joined(separator:", ")). Download them from Available → Wikimedia archives.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    } else {
                        Text(readiness(set)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }
            }
            ForEach(model.linkMaps) { map in
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:3) {
                        Text("\(map.manifest.project) · \(map.manifest.readableDate)").font(.callout.weight(.medium))
                        Text(contents(map)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        if map.manifest.version < 2 {
                            Text("Built before subcategories and other languages: Rebuild it from the same tables, plus langlinks, to add them.")
                                .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
                        }
                        Text(model.browser.linkMap?.directory == map.directory ? "In use by the open package" : "Used by \(map.manifest.project) packages when you open them")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete…",role:.destructive) { deletingMap=map }.disabled(model.linkMapBuild != nil)
                }
            }
            if !model.linkMaps.isEmpty && !model.dumpSets.isEmpty {
                Text("Once a map is built, its table dumps can be deleted to free space; they're needed only to build again.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12).background(Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:8))
    }
    /// What a build from these tables will have, and what it will lack.
    private func readiness(_ set: LinkMapLibrary.DumpSet) -> String {
        let effects=[("linktarget","dumps from 2024 on can't be read"),("categorylinks","no categories"),("langlinks","no other languages")]
        let lacking=effects.filter { set.records[$0.0] == nil }
        if lacking.isEmpty { return "Ready to build, with categories, subcategories and other languages." }
        return "Ready to build. Without "+lacking.map(\.0).joined(separator:" and ")+": "+lacking.map(\.1).joined(separator:"; ")+"."
    }
    /// "6,912,004 articles · 612 million links · 2.1 million categories · 342 languages · 9.8 GB".
    private func contents(_ map: BuiltLinkMap) -> String {
        var parts=["\(map.manifest.articles.formatted()) articles","\(map.manifest.links.formatted()) links"]
        if map.manifest.categories > 0 { parts.append("\(map.manifest.categories.formatted()) categories") }
        if let languages=map.manifest.languages, languages > 0 { parts.append("\(languages.formatted()) languages") }
        parts.append(ByteCountFormatter.string(fromByteCount:map.bytes,countStyle:.file))
        return parts.joined(separator:" · ")
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

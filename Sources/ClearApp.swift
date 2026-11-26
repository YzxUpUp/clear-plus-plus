import AppKit
import SwiftUI

private typealias ViewState<Value> = SwiftUI.State<Value>

private struct SourceCheckbox: View {
    let source: Source
    @Binding var sources: Set<Source>

    var body: some View {
        Toggle(source.title, isOn: Binding(
            get: { sources.contains(source) },
            set: { isSelected in
                if isSelected {
                    sources.insert(source)
                } else {
                    sources.remove(source)
                }
            }
        ))
        .toggleStyle(.checkbox)
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"

    var id: String { rawValue }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

enum Ordering: String, CaseIterable, Identifiable {
    case sizeDescending = "占用最大优先"
    case sizeAscending = "占用最小优先"
    case nameAscending = "名称 A–Z"
    case nameDescending = "名称 Z–A"

    var id: String { rawValue }
}

@main
struct ClearApp: App {
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage("defaultSourceFilter") private var defaultSourceFilter = SourceFilter.initial
    @StateObject private var model = InventoryModel()

    var body: some Scene {
        Window("Clear++", id: "inventory") {
            InventoryView(model: model, appearance: $appearance, defaultSources: defaultSourceFilter.sources)
                .preferredColorScheme(appearance.scheme)
                .frame(minWidth: 780, minHeight: 540)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button("重新扫描") { model.refresh() }
                    .keyboardShortcut("r")
                    .disabled(model.busy)
                Button("添加扫描位置…") { model.addScanLocation() }
                    .disabled(model.busy)
                Button("清除自定义扫描位置") { model.clearScanLocations() }
                    .disabled(model.busy || model.extraRoots.isEmpty)
            }
        }
        Settings {
            Form {
                Picker("界面外观", selection: $appearance) {
                    ForEach(Appearance.allCases) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                Section {
                    let sources = Binding(
                        get: { defaultSourceFilter.sources },
                        set: { defaultSourceFilter = SourceFilter(sources: $0) }
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Source.allCases, id: \.self) { source in
                            SourceCheckbox(source: source, sources: sources)
                        }
                    }
                    HStack {
                        Button("设为全部来源") { defaultSourceFilter = SourceFilter(sources: []) }
                            .disabled(defaultSourceFilter.sources.isEmpty)
                        Button("恢复初始默认") { defaultSourceFilter = .initial }
                            .disabled(defaultSourceFilter == .initial)
                    }
                } header: {
                    Text("默认安装来源")
                } footer: {
                    Text("打开列表时使用。全部取消勾选会显示全部来源。")
                }
            }
            .formStyle(.grouped)
            .frame(width: 440, height: 350)
            .preferredColorScheme(appearance.scheme)
        }
    }
}

@MainActor
final class InventoryModel: ObservableObject {
    @Published var inventory = Inventory()
    @Published var scanning = false
    @Published var uninstalling = false
    @Published var scanned = false
    @Published var notice: Notice?
    @Published private(set) var extraRoots = (UserDefaults.standard.stringArray(forKey: "extraRoots") ?? [])
        .map { URL(fileURLWithPath: $0) }
    private var retryRecords: [String: AppRecord] = [:]

    var busy: Bool { scanning || uninstalling }

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    func addScanLocation() {
        let panel = NSOpenPanel()
        panel.title = "添加扫描位置"
        panel.prompt = "添加"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let additions = panel.urls.map { $0.resolvingSymlinksInPath() }
        extraRoots += additions.filter { !extraRoots.contains($0) && !isSystemPath($0.path) }
        UserDefaults.standard.set(extraRoots.map(\.path), forKey: "extraRoots")
        refresh()
    }

    func clearScanLocations() {
        extraRoots = []
        UserDefaults.standard.removeObject(forKey: "extraRoots")
        refresh()
    }

    func refresh() {
        guard !busy else { return }
        scanning = true
        let scanner = Scanner(extraRoots: extraRoots)
        Task {
            var updated = await Task.detached(priority: .userInitiated) { scanner.scan() }.value
            let currentIDs = Set(updated.records.map(\.id))
            for (id, pending) in retryRecords where !currentIDs.contains(id) {
                var record = pending
                record.leftovers = pending.leftovers.filter(\.isOriginal)
                if record.leftovers.isEmpty {
                    retryRecords.removeValue(forKey: id)
                } else {
                    updated.records.append(record)
                }
            }
            inventory = updated
            scanned = true
            scanning = false
        }
    }

    func uninstall(_ plan: UninstallPlan, selected: Set<String>) {
        guard !busy else { return }
        uninstalling = true
        Task {
            if let error = await Uninstaller.quitApps(for: plan.record) {
                notice = .init(title: "暂时无法卸载", message: error)
                uninstalling = false
                return
            }
            let result = await Task.detached(priority: .userInitiated) {
                Uninstaller.remove(plan, selected: selected)
            }.value
            if result.mainRemoved {
                retryRecords.removeValue(forKey: plan.record.id)
                let pending = result.failedLeftovers.filter(\.isOriginal)
                if !pending.isEmpty {
                    var record = plan.record
                    record.primary = []
                    record.managerRoot = nil
                    record.vendorUninstaller = nil
                    record.mainSize = Size()
                    record.leftoverSize = await Task.detached { measure(pending) }.value
                    record.leftovers = pending
                    record.removal = .leftoversOnly
                    record.notes = ["程序文件已移除，可以重试清理以下关联文件。"]
                    retryRecords[record.id] = record
                }
            }
            uninstalling = false
            notice = .init(title: result.errors.isEmpty ? "卸载完成" :
                (result.removed.isEmpty ? "卸载未完成" : "部分项目未能移除"), message: result.message)
            refresh()
        }
    }
}

struct InventoryView: View {
    @ObservedObject var model: InventoryModel
    @Binding var appearance: Appearance
    let defaultSources: Set<Source>
    @AppStorage("ordering") private var ordering: Ordering = .sizeDescending
    @ViewState private var search = ""
    @ViewState private var sourceOverride: Set<Source>?
    @ViewState private var showingSourceFilters = false
    @ViewState private var selectedID: String?
    @ViewState private var plan: UninstallPlan?
    @FocusState private var searchFocused: Bool

    private var selectedSources: Set<Source> {
        get { sourceOverride ?? defaultSources }
        nonmutating set { sourceOverride = newValue == defaultSources ? nil : newValue }
    }

    private var records: [AppRecord] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.inventory.records.filter { record in
            (selectedSources.isEmpty || selectedSources.contains(record.source)) &&
                (term.isEmpty || ([record.name, record.bundleID ?? "", record.location?.lastPathComponent ?? ""]
                    + Array(record.appNames)).contains { $0.localizedStandardContains(term) })
        }.sorted { first, second in
            let names = first.name.localizedStandardCompare(second.name)
            switch ordering {
            case .sizeDescending, .sizeAscending:
                if first.total.bytes != second.total.bytes {
                    return ordering == .sizeDescending ? first.total.bytes > second.total.bytes : first.total.bytes < second.total.bytes
                }
                return names == .orderedSame ? first.id < second.id : names == .orderedAscending
            case .nameAscending, .nameDescending:
                return names == .orderedSame ? first.id < second.id :
                    names == (ordering == .nameAscending ? .orderedAscending : .orderedDescending)
            }
        }
    }

    private var selected: AppRecord? { records.first { $0.id == selectedID } }
    private var sources: [Source] {
        let available = Set(model.inventory.records.map(\.source)).union(selectedSources)
        return Source.allCases.filter { available.contains($0) }
    }

    private var sourceLabel: String {
        if selectedSources.isEmpty { return "全部来源" }
        if selectedSources.count == 1, let source = selectedSources.first { return source.title }
        return "已选 \(selectedSources.count) 个来源"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                results.frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
                detail.frame(minWidth: 290, idealWidth: 330, maxWidth: 410, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .onAppear { if !model.scanned { model.refresh() } }
        .onChange(of: defaultSources) { _, _ in sourceOverride = nil }
        .onChange(of: records.map(\.id)) { _, ids in
            if !ids.contains(selectedID ?? "") { selectedID = ids.first }
        }
        .sheet(item: $plan) { plan in
            ConfirmView(plan: plan) { selected in
                self.plan = nil
                model.uninstall(plan, selected: selected)
            }
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("好")))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索应用名称或标识符", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("搜索应用名称或标识符")
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
            .frame(minWidth: 165, maxWidth: 380)
            .background {
                Button("搜索") { searchFocused = true }.keyboardShortcut("f").hidden()
            }

            sourceFilter
            Menu {
                Picker("排序方式", selection: $ordering) {
                    ForEach(Ordering.allCases) { item in Text(item.rawValue).tag(item) }
                }
            } label: {
                Label(ordering.rawValue, systemImage: "arrow.up.arrow.down")
            }
            .fixedSize()
            Spacer(minLength: 4)
            Menu {
                Picker("界面外观", selection: $appearance) {
                    ForEach(Appearance.allCases) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                    }
                }
            } label: {
                Image(systemName: appearance.symbol)
            }
            .fixedSize()
            .help("界面外观")
            .accessibilityLabel("界面外观")
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise").padding(.horizontal, 3)
            }
            .disabled(model.busy)
            .help("重新扫描 ⌘R")
            .accessibilityLabel("重新扫描")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sourceFilter: some View {
        Button {
            showingSourceFilters.toggle()
        } label: {
            HStack(spacing: 7) {
                Label(sourceLabel, systemImage: "line.3.horizontal.decrease")
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .fixedSize()
        .disabled(sources.isEmpty)
        .help("筛选安装来源")
        .accessibilityLabel("安装来源")
        .accessibilityValue(sourceLabel)
        .popover(isPresented: $showingSourceFilters, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("安装来源").font(.headline)
                ForEach(sources, id: \.self) { source in
                    SourceCheckbox(source: source, sources: Binding(
                        get: { selectedSources },
                        set: { selectedSources = $0 }
                    ))
                }
                Divider()
                HStack {
                    Button("显示全部来源") { selectedSources = [] }
                        .disabled(selectedSources.isEmpty)
                    Button("应用默认来源") { sourceOverride = nil }
                        .disabled(sourceOverride == nil)
                }
            }
            .frame(minWidth: 180, alignment: .leading)
            .padding(14)
        }
    }

    private var results: some View {
        Group {
            if records.isEmpty {
                VStack(spacing: 12) {
                    if model.scanning && !model.scanned {
                        ProgressView()
                        Text("正在扫描应用和磁盘占用").foregroundStyle(.secondary)
                    } else {
                        let filtering = !search.isEmpty || !selectedSources.isEmpty
                        Image(systemName: filtering ? "magnifyingglass" : "square.grid.2x2")
                            .font(.system(size: 35)).foregroundStyle(.tertiary)
                        Text(filtering ? "没有匹配的软件" : "没有可显示的软件")
                            .font(.headline)
                        if filtering {
                            Button("清除筛选") {
                                search = ""
                                selectedSources = []
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("名称")
                        Spacer()
                        Text("磁盘占用")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 21)
                    .padding(.vertical, 8)
                    Divider()
                    List(records, selection: $selectedID) { record in
                        HStack(spacing: 11) {
                            ProgramIcon(record: record, size: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.name).font(.body.weight(.medium)).lineLimit(1)
                                Text(record.source.title + (record.version.isEmpty ? "" : " · " + record.version))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(record.total.text)
                                .font(.callout.monospacedDigit()).lineLimit(1)
                        }
                        .padding(.vertical, 4)
                        .tag(record.id)
                    }
                    .listStyle(.inset)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private var detail: some View {
        if let selected {
            DetailView(record: selected, busy: model.busy) {
                plan = UninstallPlan(record: selected)
            }
            .id(selected.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "sidebar.right").font(.system(size: 32)).foregroundStyle(.tertiary)
                Text("选择软件查看详情").foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        let partial = records.contains { $0.total.partial }
        return HStack(spacing: 8) {
            if model.busy {
                ProgressView().controlSize(.small)
                Text(model.uninstalling ? "正在卸载…" : "正在扫描…")
            } else {
                Text("\(records.count) 项软件")
                if partial {
                    Text("· 部分文件无法读取").help("带 ≥ 的数字表示已读取部分的占用。")
                }
            }
            if !model.inventory.notices.isEmpty {
                Image(systemName: "exclamationmark.circle")
                    .help(model.inventory.notices.joined(separator: "\n"))
                    .accessibilityLabel(model.inventory.notices.joined(separator: " "))
            }
            Spacer()
            Text("按磁盘分配空间计算")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 17)
        .padding(.vertical, 8)
    }
}

struct ProgramIcon: View {
    let record: AppRecord
    let size: CGFloat

    var body: some View {
        Group {
            if let app = record.appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable().scaledToFit()
            } else {
                Image(systemName: record.source.symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.25))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct DetailView: View {
    let record: AppRecord
    let busy: Bool
    let uninstall: () -> Void
    @ViewState private var showVendorConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        ProgramIcon(record: record, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.name).font(.title3.weight(.semibold))
                                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            Text(record.source.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("磁盘占用").font(.subheadline.weight(.medium))
                            Spacer()
                            Text(record.total.text).font(.title2.weight(.semibold).monospacedDigit())
                        }
                        Divider()
                        sizeRow("程序文件", record.mainSize.text)
                        sizeRow("关联文件", record.leftoverSize.text)
                    }
                    .padding(13)
                    .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))

                    if let url = record.location {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("安装位置").font(.subheadline.weight(.semibold))
                            Text(url.path).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled).lineLimit(3)
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            .controlSize(.small)
                        }
                    }

                    if !record.leftovers.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("关联文件").font(.subheadline.weight(.semibold))
                            ForEach(Dictionary(grouping: record.leftovers, by: \.category)
                                .keys.sorted(), id: \.self) { key in
                                let count = record.leftovers.filter { $0.category == key }.count
                                sizeRow(key, "\(count) 项")
                            }
                        }
                    }
                    ForEach(record.notes, id: \.self) { note in
                        Text(note).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            }
            Divider()
            HStack {
                switch record.removal {
                case .currentApp:
                    Text("Clear++ 正在运行").font(.callout).foregroundStyle(.secondary)
                case .manual:
                    Text("请使用厂商卸载器").font(.callout).foregroundStyle(.secondary)
                case .trash, .brew, .leftoversOnly:
                    if record.vendorUninstaller != nil {
                        Button("打开厂商卸载器…") { showVendorConfirmation = true }
                            .disabled(busy)
                    }
                    Spacer()
                    Button(role: .destructive, action: uninstall) {
                        Label(record.primary.isEmpty ? "清理…" : "卸载…", systemImage: "trash").padding(.horizontal, 5)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(busy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(14)
        }
        .confirmationDialog("打开 \(record.name) 的厂商卸载器？",
                            isPresented: $showVendorConfirmation, titleVisibility: .visible) {
            Button("打开卸载器") {
                if let vendor = record.vendorUninstaller { NSWorkspace.shared.open(vendor) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func sizeRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

struct ConfirmView: View {
    let plan: UninstallPlan
    let confirm: (Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selected: Set<String>

    init(plan: UninstallPlan, confirm: @escaping (Set<String>) -> Void) {
        self.plan = plan
        self.confirm = confirm
        _selected = ViewState(wrappedValue: Set(plan.record.leftovers.map(\.id)))
    }

    private var instruction: String {
        switch plan.record.removal {
        case .brew: "Clear++ 将调用 Homebrew 卸载程序，并把勾选的关联文件移到废纸篓。"
        case .leftoversOnly: "勾选的关联文件将移到废纸篓。"
        default: "主程序和勾选的关联文件将移到废纸篓。请先保存该软件中的工作。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ProgramIcon(record: plan.record, size: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(plan.record.primary.isEmpty ? "清理 \(plan.record.name) 的关联文件？" : "卸载 \(plan.record.name)？")
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(instruction).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let note = plan.record.notes.first {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if !plan.record.primary.isEmpty {
                        Text("程序文件").font(.subheadline.weight(.semibold))
                    }
                    ForEach(plan.record.primary) { item in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "shippingbox").foregroundStyle(.secondary)
                            Text(item.id).font(.caption).textSelection(.enabled)
                        }
                        .help(item.id)
                    }
                    if !plan.record.leftovers.isEmpty {
                        Divider().padding(.vertical, 3)
                        HStack {
                            Text("关联文件").font(.subheadline.weight(.semibold))
                            Spacer()
                            Button(selected.count == plan.record.leftovers.count ? "取消全选" : "全选") {
                                selected = selected.count == plan.record.leftovers.count ? [] :
                                    Set(plan.record.leftovers.map(\.id))
                            }
                            .buttonStyle(.link)
                        }
                        Text("应用支持和沙盒数据可能包含应用内下载或本地记录。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(plan.record.leftovers) { item in
                            Toggle(isOn: Binding(
                                get: { selected.contains(item.id) },
                                set: { value in
                                    if value { selected.insert(item.id) } else { selected.remove(item.id) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.category)
                                    Text(item.id).font(.caption).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .help(item.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(idealHeight: 225, maxHeight: 290)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(plan.record.primary.isEmpty ? "确认清理" : "确认卸载", role: .destructive) {
                    confirm(selected)
                }
                    .disabled(plan.record.primary.isEmpty && selected.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}

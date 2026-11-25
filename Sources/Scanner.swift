import Darwin
import Foundation

struct Scanner: Sendable {
    let home: URL
    let currentApp: URL?
    let extraRoots: [URL]
    private var fm: FileManager { .default }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, currentApp: URL? = Bundle.main.bundleURL,
         extraRoots: [URL] = []) {
        self.home = home.resolvingSymlinksInPath()
        self.currentApp = currentApp.map(normalized)
        self.extraRoots = extraRoots.map { $0.resolvingSymlinksInPath() }
    }

    private var userLibrary: URL { home.appendingPathComponent("Library") }
    private var systemLibrary: URL { URL(fileURLWithPath: "/Library") }
    private let appRoots = ["/Applications", "/Users/Shared/Applications"]
    private let pkgutil = URL(fileURLWithPath: "/usr/sbin/pkgutil")
    private let dataFolders = [
        ("Application Support", "应用支持数据"), ("Application Scripts", "应用脚本"),
        ("Caches", "缓存"), ("HTTPStorages", "网络缓存"), ("WebKit", "WebKit 数据"),
        ("Logs", "日志"), ("Logs/DiagnosticReports", "诊断日志"),
        ("Preferences", "偏好设置"), ("Preferences/ByHost", "偏好设置"),
        ("Saved Application State", "窗口状态"), ("Containers", "沙盒数据")
    ]

    func scan() -> Inventory {
        var result = Inventory()
        var applications = discoverApplications(&result.notices)
        let receipts = discoverReceipts(apps: applications, notices: &result.notices)
        let managed = discoverBrew(&applications, receipts: receipts, notices: &result.notices)
        var consumedReceipts = managed.receipts

        for path in applications.keys.sorted() {
            guard var record = applications[path] else { continue }
            let owned = receipts.filter { receipt in
                receipt.items.contains { inside($0.id, path) }
            }
            if !owned.isEmpty && record.source != .appStore {
                record.source = .installer
            }
            for receipt in owned where receipt.items.allSatisfy({ inside($0.id, path) }) {
                consumedReceipts.insert(receipt.id)
            }
            if owned.contains(where: { receipt in receipt.items.contains { !inside($0.id, path) } }) {
                record.notes.append("安装包还部署了其他组件。完整移除请优先使用厂商卸载器。")
            }
            record.vendorUninstaller = vendorUninstaller(for: record)
            if record.vendorUninstaller != nil && record.notes.isEmpty {
                record.notes.append("发现厂商卸载器。它可以处理该软件自带的后台组件。")
            }
            result.records.append(record)
        }

        result.records.append(contentsOf: managed.records)
        let appPaths = result.records.flatMap(\.primary).map(\.id)
        for receipt in receipts where !consumedReceipts.contains(receipt.id) {
            let items = receipt.items.filter { item in !appPaths.contains { inside(item.id, $0) } }
            guard !items.isEmpty else { continue }
            result.records.append(.init(id: "receipt:" + receipt.id, name: receipt.id,
                source: .receipt, version: receipt.version, bundleID: nil, primary: items,
                removal: .manual, notes: ["安装记录列出了这些组件。请使用厂商卸载器移除。"]))
        }

        assignLeftovers(to: &result.records, declared: managed.leftovers)
        for index in result.records.indices {
            result.records[index].mainSize = measure(result.records[index].primary)
            result.records[index].leftoverSize = measure(result.records[index].leftovers)
        }
        return result
    }

    private func discoverApplications(_ notices: inout [String]) -> [String: AppRecord] {
        let roots = appRoots.map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent("Applications")] + extraRoots
        var candidates: [URL] = []
        for root in roots where !isSystemPath(root.path) && fm.fileExists(atPath: root.path) {
            let explicitLibrary = inside(root.path, userLibrary.path) || inside(root.path, systemLibrary.path)
            if root.pathExtension.lowercased() == "app" {
                candidates.append(root)
                continue
            }
            let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isPackageKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in true })
            guard let iterator else { continue }
            for case let url as URL in iterator {
                if isSystemPath(url.path) ||
                    (!explicitLibrary && (url.path == userLibrary.path || url.path == systemLibrary.path)) {
                    iterator.skipDescendants()
                } else if url.pathExtension.lowercased() == "app" {
                    candidates.append(url)
                    iterator.skipDescendants()
                } else if (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                    iterator.skipDescendants()
                }
            }
        }
        let spotlight = command(URL(fileURLWithPath: "/usr/bin/mdfind"),
            ["-0", "kMDItemContentType == 'com.apple.application-bundle'"], separateErrors: true)
        if spotlight.status == 0 {
            candidates += spotlight.output.split(separator: "\0").map { URL(fileURLWithPath: String($0)) }
        } else {
            notices.append("Spotlight 索引暂不可用，已扫描常用应用目录。")
        }
        return candidates.reduce(into: [:]) { records, url in
            let url = normalized(url)
            let explicit = extraRoots.contains {
                inside(url.path, $0.path) && (inside($0.path, userLibrary.path) || inside($0.path, systemLibrary.path))
            }
            guard records[url.path] == nil, let record = application(at: url, allowLibrary: explicit) else { return }
            records[url.path] = record
        }
    }

    private func application(at url: URL, allowLibrary: Bool = false) -> AppRecord? {
        let path = url.path
        let excluded = [home.appendingPathComponent(".Trash").path, userLibrary.path,
                        "/Library", "/opt/homebrew", "/usr/local/Cellar", "/usr/local/Caskroom"]
        guard !isSystemPath(path),
            allowLibrary || !excluded.contains(where: { inside(path, $0) }),
            !url.deletingLastPathComponent().pathComponents.contains(where: {
                let part = $0.lowercased()
                return part.hasSuffix(".app") || part.hasSuffix(".bundle") ||
                    part.hasSuffix(".framework") || part.hasSuffix(".plugin") ||
                    part.hasSuffix(".xpc") || part.hasSuffix(".jdk") || part.hasSuffix(".appex") ||
                    [".trashes", ".trash", ".build", ".git", "node_modules", "deriveddata", "apptranslocation"].contains(part)
            }),
            (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) != true,
            let item = Item(url, category: "主程序"), item.identity.type == mode_t(S_IFDIR),
            let bundle = Bundle(url: url), bundle.executableURL != nil,
            let id = bundle.bundleIdentifier, !id.isEmpty
        else { return nil }

        let base = url.deletingPathExtension().lastPathComponent
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? base
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ??
            bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let store = fm.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
        let isCurrent = path == currentApp?.path
        return .init(id: "app:" + path, name: name, source: store ? .appStore : .application,
                     version: version, bundleID: id, appNames: [name, base], primary: [item],
                     removal: isCurrent ? .currentApp : .trash)
    }

    private func vendorUninstaller(for record: AppRecord) -> URL? {
        guard let app = record.appURL,
              !app.lastPathComponent.lowercased().contains("uninstall") else { return nil }
        let base = app.deletingPathExtension().lastPathComponent
        let parent = app.deletingLastPathComponent()
        let paths = [
            parent.appendingPathComponent(base + "Uninstaller.app"),
            parent.appendingPathComponent(base + " Uninstaller.app"),
            parent.appendingPathComponent("Uninstall " + base + ".app"),
            parent.appendingPathComponent(base + "卸载.app")
        ]
        return paths.first { application(at: $0) != nil }
    }

    private struct Receipt {
        let id: String
        let version: String
        let items: [Item]
    }

    private func discoverReceipts(apps: [String: AppRecord], notices: inout [String]) -> [Receipt] {
        let appSpellings = Dictionary(grouping: apps.keys, by: { $0.lowercased() })
        let ids = command(pkgutil, ["--pkgs"], separateErrors: true)
        guard ids.status == 0 else {
            notices.append("系统安装包记录暂不可用。")
            return []
        }
        return ids.output.split(whereSeparator: \.isNewline).compactMap { id in
            guard !id.hasPrefix("com.apple."), !id.hasPrefix("-") else { return nil }
            let info = command(pkgutil, ["--pkg-info-plist", String(id)], separateErrors: true)
            guard let plist = (try? PropertyListSerialization.propertyList(from: info.data,
                format: nil)) as? [String: Any] else { return nil }
            let base = URL(fileURLWithPath: plist["volume"] as? String ?? "/")
                .appendingPathComponent(plist["install-location"] as? String ?? "").standardizedFileURL
            let payload = command(pkgutil, ["--files", String(id)], separateErrors: true)
            guard payload.status == 0 else { return nil }
            var items: [Item] = []
            var seen: Set<String> = []
            let bundles = Set(["app", "jdk", "plugin", "driver", "kext", "framework", "systemextension",
                               "bundle", "prefpane", "component", "vst", "vst3", "qlgenerator", "mdimporter", "dext"])
            for entry in payload.output.split(whereSeparator: \.isNewline) {
                let components = entry.split(separator: "/").filter { $0 != "." }
                guard !components.contains("..") else { continue }
                var target = base
                if !bundles.contains(target.pathExtension.lowercased()) {
                    for component in components {
                        target.appendPathComponent(String(component))
                        if bundles.contains(target.pathExtension.lowercased()) { break }
                    }
                }
                target = normalized(target)
                if let known = appSpellings[target.path.lowercased()]?.first(where: { path in
                    guard let identity = apps[path]?.primary.first?.identity, let info = fileInfo(target) else {
                        return false
                    }
                    return identity == FileIdentity(info)
                }) {
                    target = URL(fileURLWithPath: known)
                }
                guard !isSystemPath(target.path), seen.insert(target.path).inserted,
                    let item = Item(target, category: "安装包组件"),
                    item.identity.type != mode_t(S_IFDIR) || bundles.contains(target.pathExtension.lowercased())
                else { continue }
                items.append(item)
            }
            guard !items.isEmpty else { return nil }
            return .init(id: String(id), version: plist["pkg-version"] as? String ?? "", items: uniqueRoots(items))
        }
    }

    private struct Managed {
        var records: [AppRecord] = []
        var receipts: Set<String> = []
        var leftovers: [String: [Item]] = [:]
    }

    private func discoverBrew(_ apps: inout [String: AppRecord], receipts: [Receipt],
                              notices: inout [String]) -> Managed {
        let configured = ProcessInfo.processInfo.environment["HOMEBREW_BREW_FILE"]
        let paths = [configured, "/opt/homebrew/bin/brew", "/usr/local/bin/brew",
                     home.appendingPathComponent("homebrew/bin/brew").path].compactMap { $0 }
        var seen: Set<String> = []
        var managed = Managed()
        for path in paths where fm.isExecutableFile(atPath: path) {
            let executable = URL(fileURLWithPath: path)
            guard seen.insert(executable.resolvingSymlinksInPath().path).inserted else { continue }
            let prefix = executable.deletingLastPathComponent().deletingLastPathComponent()
            let inventory = command(executable, ["info", "--json=v2", "--installed"], brew: true, separateErrors: true)
            guard inventory.status == 0,
                  let data = (try? JSONSerialization.jsonObject(with: inventory.data)) as? [String: Any] else {
                notices.append("未能读取 \(prefix.path) 的 Homebrew 清单。")
                continue
            }
            let cellar = brewDirectory(executable, argument: "--cellar", fallback: prefix.appendingPathComponent("Cellar"))
            let caskroom = brewDirectory(executable, argument: "--caskroom", fallback: prefix.appendingPathComponent("Caskroom"))
            for formula in data["formulae"] as? [[String: Any]] ?? [] {
                guard let name = formula["name"] as? String, validToken(name),
                      let root = Item(normalized(cellar.appendingPathComponent(name)), category: "安装目录"),
                      root.identity.type == mode_t(S_IFDIR) else { continue }
                let versions = (formula["installed"] as? [[String: Any]] ?? []).compactMap { $0["version"] as? String }
                managed.records.append(.init(id: "formula:" + root.id, name: name, source: .formula,
                    version: versions.joined(separator: "、"), bundleID: nil, primary: [root],
                    removal: .brew(executable: executable, argument: name, formula: true), managerRoot: root,
                    notes: ["Homebrew 会检查软件包依赖。由软件包管理器移除的文件可能无法从废纸篓恢复。"]))
            }
            for cask in data["casks"] as? [[String: Any]] ?? [] {
                guard let token = cask["token"] as? String, validToken(token),
                      let root = Item(normalized(caskroom.appendingPathComponent(token)), category: "Homebrew 安装目录"),
                      root.identity.type == mode_t(S_IFDIR) else { continue }
                let record = caskRecord(cask, token: token, executable: executable, root: root,
                    prefix: prefix, apps: &apps, receipts: receipts, managed: &managed)
                managed.records.append(record)
            }
        }
        return managed
    }

    private func brewDirectory(_ executable: URL, argument: String, fallback: URL) -> URL {
        let result = command(executable, [argument], brew: true, separateErrors: true)
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && path.hasPrefix("/") ? URL(fileURLWithPath: path) : fallback
    }

    private func validToken(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value != "." && value != ".." &&
            value.range(of: "^[A-Za-z0-9_.@+-]+$", options: .regularExpression) != nil
    }

    private func caskRecord(_ cask: [String: Any], token: String, executable: URL, root: Item, prefix: URL,
                            apps: inout [String: AppRecord], receipts: [Receipt], managed: inout Managed) -> AppRecord {
        let configURL = root.url.appendingPathComponent(".metadata/config.json")
        let config = (try? Data(contentsOf: configURL)).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        } ?? [:]
        let directories = (config["default"] as? [String: String] ?? [:])
            .merging(config["explicit"] as? [String: String] ?? [:]) { _, value in value }
        let artifacts = cask["artifacts"] as? [[String: Any]] ?? []
        let kinds = [
            "app": ("appdir", "/Applications"), "font": ("fontdir", userLibrary.appendingPathComponent("Fonts").path),
            "prefpane": ("prefpanedir", userLibrary.appendingPathComponent("PreferencePanes").path),
            "qlplugin": ("qlplugindir", userLibrary.appendingPathComponent("QuickLook").path),
            "suite": ("appdir", "/Applications"), "binary": ("binarydir", prefix.appendingPathComponent("bin").path)
        ]
        var items = [root]
        var ids: Set<String> = []
        var names: Set<String> = []
        var notes = ["由 Homebrew 移除的程序文件可能无法从废纸篓恢复。"]
        let id = "cask:" + root.id
        for artifact in artifacts {
            for (kind, data) in artifact {
                if kind == "uninstall" {
                    for action in data as? [[String: Any]] ?? [] {
                        let ids = stringList(action["pkgutil"])
                        for receipt in receipts where ids.contains(where: { matches($0, receipt.id) }) {
                            managed.receipts.insert(receipt.id)
                            items += receipt.items
                        }
                    }
                }
                if kind == "zap" {
                    for action in data as? [[String: Any]] ?? [] {
                        for path in stringList(action["trash"]) + stringList(action["delete"]) {
                            managed.leftovers[id, default: []] += declaredLeftovers(path)
                        }
                    }
                }
                guard let (key, fallback) = kinds[kind], let list = data as? [Any],
                      let original = list.first as? String else { continue }
                let target = list.compactMap { ($0 as? [String: Any])?["target"] as? String }.first ??
                    URL(fileURLWithPath: original).lastPathComponent
                let directory = directories[key] ?? fallback
                let path = (target as NSString).expandingTildeInPath
                let url = normalized(path.hasPrefix("/") ? URL(fileURLWithPath: path) :
                    URL(fileURLWithPath: directory).appendingPathComponent(path))
                guard !isSystemPath(url.path), let item = Item(url, category: "已安装文件") else { continue }
                items.append(item)
                if kind == "app", let app = apps.removeValue(forKey: url.path) ?? application(at: url, allowLibrary: true) {
                    ids.formUnion([app.bundleID].compactMap { $0 })
                    names.formUnion(app.appNames)
                }
                if kind == "suite" {
                    for key in apps.keys.filter({ inside($0, url.path) }) {
                        guard let app = apps.removeValue(forKey: key) else { continue }
                        ids.formUnion([app.bundleID].compactMap { $0 })
                        names.formUnion(app.appNames)
                    }
                }
            }
        }
        let version = cask["installed"] as? String ?? cask["version"] as? String ?? ""
        if artifacts.contains(where: { $0["pkg"] != nil }) {
            notes.append("此软件包的卸载步骤可能需要管理员权限。")
        }
        let appItems = items.filter { $0.url.pathExtension.lowercased() == "app" }
        let runningThisApp = appItems.contains { $0.id == currentApp?.path }
        return .init(id: id, name: (cask["name"] as? [String])?.first ?? token,
                     source: .cask, version: version, bundleID: ids.count == 1 ? ids.first : nil,
                     appNames: ids.count == 1 ? names : [], primary: uniqueRoots(items),
                     removal: runningThisApp ? .currentApp : .brew(executable: executable, argument: token, formula: false),
                     managerRoot: root, notes: notes)
    }

    private func stringList(_ value: Any?) -> [String] {
        if let value = value as? String { return [value] }
        return value as? [String] ?? []
    }

    private func matches(_ pattern: String, _ value: String) -> Bool {
        fnmatch(pattern, value, FNM_PATHNAME) == 0
    }

    private func declaredLeftovers(_ path: String) -> [Item] {
        let expanded = path.hasPrefix("~/") ? home.path + "/" + path.dropFirst(2) : path
        guard expanded.hasPrefix("/"), !expanded.split(separator: "/").contains("..") else { return [] }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let parent = url.deletingLastPathComponent()
        let allowed = dataFolders.map { userLibrary.appendingPathComponent($0.0).path }
        guard hasStableParent(url), allowed.contains(where: { inside(parent.path, $0) }),
              !["*", "?", ""].contains(url.lastPathComponent),
              (url.lastPathComponent.prefix { !"*?[{".contains($0) }).count >= 3 else { return [] }
        if url.lastPathComponent.contains(where: { "*?[".contains($0) }) {
            return ((try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [])
                .filter { matches(url.lastPathComponent, $0.lastPathComponent) }
                .compactMap { Item($0, category: "Homebrew 清理项") }
        }
        return [Item(url, category: "Homebrew 清理项")].compactMap { $0 }
    }

    private func assignLeftovers(to records: inout [AppRecord], declared: [String: [Item]]) {
        let primary = records.flatMap(\.primary).map(\.id)
        var claims: [String: [Int: Item]] = [:]
        let names = records.map { $0.appNames.map { $0.lowercased() }.filter { $0.count >= 3 } }
        let bundleIDs = records.map { $0.bundleID?.lowercased() }
        let vendorFolders = [
            "com.google.chrome": "Google/Chrome",
            "com.google.chrome.beta": "Google/Chrome Beta",
            "com.google.chrome.dev": "Google/Chrome Dev",
            "com.google.chrome.canary": "Google/Chrome Canary",
            "com.brave.browser": "BraveSoftware/Brave-Browser"
        ]
        for (index, id) in bundleIDs.enumerated() {
            guard let id, let directory = vendorFolders[id] else { continue }
            for (root, label) in dataFolders where ["Application Support", "Caches", "Logs"].contains(root) {
                let url = userLibrary.appendingPathComponent(root).appendingPathComponent(directory)
                if hasStableParent(url), let item = Item(url, category: label) {
                    claims[item.id, default: [:]][index] = item
                }
            }
        }
        let twoLibraries = [userLibrary, systemLibrary]
        for library in twoLibraries {
            for (folder, label) in dataFolders {
                let path = library.appendingPathComponent(folder)
                guard let children = try? fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles]) else { continue }
                for url in children where hasStableParent(url) {
                    let filename = url.lastPathComponent.lowercased()
                    for index in records.indices {
                        let id = bundleIDs[index]
                        let exact = id.map { identifier in
                            filename == identifier || filename == identifier + ".plist" ||
                                filename == identifier + ".binarycookies" || filename == identifier + ".savedstate" ||
                                (folder == "Preferences/ByHost" && filename.hasPrefix(identifier + ".") && filename.hasSuffix(".plist"))
                        } ?? false
                        let namedFolder = ["Application Support", "Caches", "Logs"].contains(folder)
                        let name = library == userLibrary && namedFolder &&
                            names[index].contains { filename == $0 || (folder == "Logs" && filename == $0 + ".log") }
                        let diagnostics = folder == "Logs/DiagnosticReports" && names[index].contains {
                            filename.hasPrefix($0 + "-20") &&
                                [".ips", ".crash", ".hang", ".diag", ".spin"].contains(where: { filename.hasSuffix($0) })
                        }
                        guard exact || name || diagnostics, let item = Item(url, category: label) else { continue }
                        claims[item.id, default: [:]][index] = item
                    }
                }
            }
        }
        for index in records.indices {
            for item in declared[records[index].id] ?? [] {
                if claims[item.id]?[index] == nil {
                    claims[item.id, default: [:]][index] = item
                }
            }
        }
        let claimedPaths = claims.keys.sorted()
        for path in claimedPaths {
            guard let owners = claims[path], owners.count == 1, let (index, item) = owners.first,
                  !primary.contains(where: { inside(path, $0) || inside($0, path) }),
                  !claimedPaths.contains(where: { other in path != other &&
                      (inside(path, other) || inside(other, path)) && claims[other]?.keys.sorted() != [index] })
            else { continue }
            records[index].leftovers.append(item)
        }
        for index in records.indices {
            records[index].leftovers = uniqueRoots(records[index].leftovers).sorted {
                ($0.category, $0.id) < ($1.category, $1.id)
            }
        }
    }
}

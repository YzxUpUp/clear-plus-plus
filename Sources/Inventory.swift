import Darwin
import Foundation

enum Source: String, CaseIterable, Sendable {
    case application = "独立应用"
    case appStore = "App Store"
    case installer = "安装包应用"
    case cask = "Homebrew Cask"
    case formula = "Homebrew Formula"
    case receipt = "安装包组件"

    var symbol: String {
        switch self {
        case .application, .appStore, .installer: "app.dashed"
        case .cask, .formula: "shippingbox"
        case .receipt: "puzzlepiece.extension"
        }
    }
}

enum Removal: Sendable {
    case trash
    case leftoversOnly
    case brew(executable: URL, argument: String, formula: Bool)
    case manual
    case currentApp
}

struct FileIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let type: mode_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        type = info.st_mode & mode_t(S_IFMT)
    }
}

struct Item: Identifiable, Sendable {
    let url: URL
    let identity: FileIdentity
    let category: String
    var id: String { url.path }

    init?(_ url: URL, category: String) {
        guard let info = fileInfo(url) else { return nil }
        self.url = url.standardizedFileURL
        self.identity = FileIdentity(info)
        self.category = category
    }

    var isOriginal: Bool {
        hasStableParent(url) && fileInfo(url).map(FileIdentity.init) == identity
    }
}

struct Size: Sendable {
    var bytes: Int64 = 0
    var partial = false

    static func + (left: Self, right: Self) -> Self {
        .init(bytes: left.bytes + right.bytes, partial: left.partial || right.partial)
    }

    var text: String {
        if partial && bytes == 0 { return "—" }
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return partial ? "≥ " + formatted : formatted
    }
}

struct AppRecord: Identifiable, Sendable {
    let id: String
    var name: String
    var source: Source
    var version: String
    var bundleID: String?
    var appNames: Set<String> = []
    var primary: [Item]
    var leftovers: [Item] = []
    var removal: Removal
    var managerRoot: Item?
    var notes: [String] = []
    var vendorUninstaller: URL?
    var mainSize = Size()
    var leftoverSize = Size()
    var total: Size { mainSize + leftoverSize }
    var appURL: URL? { primary.first { $0.url.pathExtension.lowercased() == "app" }?.url }
    var location: URL? { appURL ?? primary.first?.url ?? managerRoot?.url }
}

struct Inventory: Sendable {
    var records: [AppRecord] = []
    var notices: [String] = []
}

func fileInfo(_ url: URL) -> stat? {
    var info = stat()
    return url.withUnsafeFileSystemRepresentation { path in
        guard let path, lstat(path, &info) == 0 else { return nil }
        return info
    }
}

func normalized(_ url: URL) -> URL {
    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    return parent.appendingPathComponent(url.lastPathComponent).standardizedFileURL
}

func hasStableParent(_ url: URL) -> Bool {
    normalized(url).path == url.standardizedFileURL.path
}

func inside(_ path: String, _ root: String) -> Bool {
    path == root || path.hasPrefix(root == "/" ? root : root + "/")
}

func isSystemPath(_ path: String) -> Bool {
    ["/System", "/usr", "/bin", "/sbin", "/private", "/Library/Apple", "/Applications/Safari.app",
     "/Volumes/Preboot", "/Volumes/Recovery"].contains { root in
        inside(path, root) && !inside(path, "/usr/local")
    }
}

func uniqueRoots(_ items: [Item]) -> [Item] {
    var roots: [Item] = []
    for item in items.sorted(by: { ($0.id.count, $0.id) < ($1.id.count, $1.id) })
        where !roots.contains(where: { inside(item.id, $0.id) }) {
        roots.append(item)
    }
    return roots
}

func measure(_ items: [Item]) -> Size {
    var result = Size()
    var hardLinks = Set<String>()
    func add(_ info: stat) {
        if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink > 1,
           !hardLinks.insert("\(info.st_dev):\(info.st_ino)").inserted { return }
        result.bytes += max(0, info.st_blocks) * 512
    }
    for item in uniqueRoots(items) {
        guard item.isOriginal, let info = fileInfo(item.url) else {
            result.partial = true
            continue
        }
        add(info)
        guard item.identity.type == mode_t(S_IFDIR) else { continue }
        guard let children = FileManager.default.enumerator(
            at: item.url, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, _ in result.partial = true; return true }
        ) else {
            result.partial = true
            continue
        }
        for case let child as URL in children {
            guard let info = fileInfo(child) else { result.partial = true; continue }
            if info.st_dev != item.identity.device {
                children.skipDescendants()
                continue
            }
            add(info)
        }
    }
    return result
}

struct CommandResult {
    let status: Int32
    let data: Data
    let timedOut: Bool
    var output: String { String(decoding: data, as: UTF8.self) }
}

func command(_ executable: URL, _ arguments: [String], brew: Bool = false,
             timeout: TimeInterval = 20, separateErrors: Bool = false) -> CommandResult {
    let process = Process()
    let pipe = Pipe()
    let signal = DispatchSemaphore(value: 0)
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = separateErrors ? FileHandle.nullDevice : pipe
    var environment = ProcessInfo.processInfo.environment
    if brew {
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_AUTOREMOVE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NONINTERACTIVE"] = "1"
        environment["SUDO_ASKPASS"] = "/usr/bin/false"
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
    }
    process.environment = environment
    process.terminationHandler = { _ in signal.signal() }
    do {
        try process.run()
    } catch {
        return .init(status: -1, data: Data(error.localizedDescription.utf8), timedOut: false)
    }
    let output = OutputBuffer()
    let read = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        output.data = pipe.fileHandleForReading.readDataToEndOfFile()
        read.signal()
    }
    let deadline = DispatchTime.now() + timeout
    let timedOut = signal.wait(timeout: deadline) == .timedOut
    if timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    guard read.wait(timeout: timedOut ? .now() + 1 : deadline) == .success else {
        return .init(status: -1, data: Data(), timedOut: true)
    }
    return .init(status: timedOut ? -1 : process.terminationStatus, data: output.data, timedOut: timedOut)
}

private final class OutputBuffer: @unchecked Sendable {
    var data = Data()
}

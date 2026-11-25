import AppKit
import Foundation

struct UninstallPlan: Identifiable, Sendable {
    let record: AppRecord
    var id: String { record.id }
}

struct UninstallResult: Sendable {
    var removed: [String] = []
    var mainRemoved = false
    var failedLeftovers: [Item] = []
    var errors: [String] = []

    var message: String {
        let summary = removed.isEmpty ? "" : "已移除 \(removed.count) 项。"
        return ([summary] + errors).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

enum Uninstaller {
    @MainActor
    static func quitApps(for record: AppRecord) async -> String? {
        let paths = record.primary.map(\.id)
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard let url = app.bundleURL else { return false }
            let path = url.resolvingSymlinksInPath().path
            return paths.contains { inside(path, $0) }
        }
        guard !running.isEmpty else { return nil }
        for app in running where !app.isTerminated { _ = app.terminate() }
        for _ in 0..<30 {
            if running.allSatisfy(\.isTerminated) { return nil }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let names = running.filter { !$0.isTerminated }.compactMap(\.localizedName).joined(separator: "、")
        return "请先退出 \(names.isEmpty ? record.name : names)，再重试卸载。"
    }

    static func remove(_ plan: UninstallPlan, selected: Set<String>,
                       trash: (URL) throws -> Void = moveToTrash) -> UninstallResult {
        let record = plan.record
        var result = UninstallResult()
        guard let changed = record.primary.first(where: { !$0.isOriginal || isSystemPath($0.id) }) else {
            switch record.removal {
            case .manual, .currentApp:
                result.errors.append("这项软件需要使用相应的卸载方式。")
                return result
            case .leftoversOnly:
                break
            case .trash:
                for item in record.primary where !trashItem(item, trash: trash, result: &result) { return result }
            case let .brew(executable, argument, formula):
                guard let root = record.managerRoot, root.isOriginal,
                      FileManager.default.isExecutableFile(atPath: executable.path) else {
                    result.errors.append("Homebrew 安装状态已变化，请重新扫描。")
                    return result
                }
                guard removeBrew(executable, argument: argument, formula: formula, root: root,
                                 result: &result) else { return result }
            }
            result.mainRemoved = true
            for item in record.leftovers where selected.contains(item.id) {
                if !trashItem(item, trash: trash, result: &result) {
                    result.failedLeftovers.append(item)
                }
            }
            return result
        }
        result.errors.append("文件已变化，请重新扫描后再试。\n" + changed.id)
        return result
    }

    private static func removeBrew(_ executable: URL, argument: String, formula: Bool, root: Item,
                                   result: inout UninstallResult) -> Bool {
        let arguments = ["uninstall", formula ? "--formula" : "--cask", argument]
        var installed = kegNames(in: root.url)
        let attempts = formula ? max(installed.count, 1) : 1
        for _ in 0..<attempts {
            let operation = command(executable, arguments, brew: true, timeout: 60)
            guard operation.status == 0 else {
                let detail = operation.output.trimmingCharacters(in: .whitespacesAndNewlines)
                result.errors.append(operation.timedOut
                    ? "Homebrew 卸载超时，请检查软件包状态后重试。"
                    : String((detail.isEmpty ? "Homebrew 无法卸载此软件包。" : detail).suffix(3000)))
                return false
            }
            if fileInfo(root.url) == nil {
                result.removed.append(root.id)
                return true
            }
            let remaining = kegNames(in: root.url)
            if formula && remaining.isStrictSubset(of: installed) {
                result.removed += installed.subtracting(remaining).sorted().map { root.id + "/" + $0 }
                if remaining.isEmpty { return true }
                installed = remaining
                continue
            }
            break
        }
        result.errors.append("Homebrew 仍保留安装记录，请查看该软件包后重试。")
        return false
    }

    private static func kegNames(in url: URL) -> Set<String> {
        let directories = (try? FileManager.default.contentsOfDirectory(at: url,
                            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return Set(directories.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("INSTALL_RECEIPT.json").path)
        }.map(\.lastPathComponent))
    }

    private static func trashItem(_ item: Item, trash: (URL) throws -> Void,
                                  result: inout UninstallResult) -> Bool {
        guard hasStableParent(item.url), !isSystemPath(item.id) else {
            result.errors.append("路径已变化，已跳过 \(item.id)")
            return false
        }
        guard let info = fileInfo(item.url) else {
            if errno == ENOENT || errno == ENOTDIR { return true }
            result.errors.append("无法访问 \(item.id)")
            return false
        }
        guard FileIdentity(info) == item.identity else {
            result.errors.append("文件已变化，已跳过 \(item.id)")
            return false
        }
        do {
            try trash(item.url)
            result.removed.append(item.id)
            return true
        } catch {
            result.errors.append("\(item.id)\n\(error.localizedDescription)")
            return false
        }
    }

    private static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

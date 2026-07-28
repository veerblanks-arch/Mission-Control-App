import AppKit
import CoreFoundation
import Foundation

struct ScreenshotMonitor {
    private let fileManager: FileManager
    private let homeDirectoryURL: URL
    private let configuredRootURL: URL?

    init(
        fileManager: FileManager = .default,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        configuredRootURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectoryURL = homeDirectoryURL
        self.configuredRootURL = configuredRootURL
    }

    func monitoredFolders() -> [URL] {
        let configuredRoot = configuredScreenshotRoot()
        var folders = [configuredRoot]
        let nestedScreenshots = configuredRoot.appendingPathComponent(
            "Screenshots",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: nestedScreenshots.path) {
            folders.append(nestedScreenshots)
        }
        return folders
    }

    func preferredSaveFolder() -> URL {
        monitoredFolders().last ?? configuredScreenshotRoot()
    }

    func screenshots(createdAfter date: Date, through endDate: Date) -> [URL] {
        var candidates: [(url: URL, date: Date)] = []

        for folder in monitoredFolders() {
            let isDedicatedScreenshotsFolder =
                folder.lastPathComponent.caseInsensitiveCompare("Screenshots") == .orderedSame
            guard let urls = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey,
                ],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in urls {
                guard isScreenshotImage(
                    url,
                    allowAnyImage: isDedicatedScreenshotsFolder
                ) else {
                    continue
                }

                let values = try? url.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey,
                ])
                let modificationDate = values?.contentModificationDate ?? .distantPast
                guard
                    modificationDate > date,
                    modificationDate <= endDate,
                    values?.isRegularFile == true,
                    (values?.fileSize ?? 0) > 0
                else {
                    continue
                }
                candidates.append((url, modificationDate))
            }
        }

        var seen = Set<String>()
        return candidates
            .sorted { $0.date < $1.date }
            .map(\.url)
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func configuredScreenshotRoot() -> URL {
        if let configuredRootURL {
            return configuredRootURL.standardizedFileURL
        }

        let applicationID = "com.apple.screencapture" as CFString
        let configuredPath = CFPreferencesCopyAppValue(
            "location" as CFString,
            applicationID
        ) as? String

        guard let configuredPath, !configuredPath.isEmpty else {
            return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? homeDirectoryURL.appendingPathComponent("Desktop", isDirectory: true)
        }

        let expandedPath = (configuredPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL
    }

    private func isScreenshotImage(_ url: URL, allowAnyImage: Bool) -> Bool {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
        guard imageExtensions.contains(url.pathExtension.lowercased()) else {
            return false
        }

        if allowAnyImage {
            return true
        }

        let filename = url.lastPathComponent.lowercased()
        return filename.contains("screenshot") || filename.contains("screen shot")
    }
}

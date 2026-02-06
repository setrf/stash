import Foundation

struct FileScanner {
    static func scan(rootURL: URL) -> [FileItem] {
        var files: [FileItem] = []
        let rootPath = rootURL.path
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return files
        }

        for case let url as URL in enumerator {
            if url.path.contains("/.stash/") || url.lastPathComponent == ".stash" {
                if url.lastPathComponent == ".stash" {
                    enumerator.skipDescendants()
                }
                continue
            }

            let relative = url.path.replacingOccurrences(of: rootPath + "/", with: "")
            if relative.isEmpty {
                continue
            }

            let depth = relative.split(separator: "/").count - 1
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            files.append(
                FileItem(
                    id: relative,
                    relativePath: relative,
                    name: url.lastPathComponent,
                    depth: max(depth, 0),
                    isDirectory: isDirectory
                )
            )
        }

        files.sort(by: compareHierarchy)

        return files
    }

    static func signature(for files: [FileItem]) -> Int {
        var hasher = Hasher()
        for item in files {
            hasher.combine(item.relativePath)
            hasher.combine(item.isDirectory)
        }
        return hasher.finalize()
    }

    private static func compareHierarchy(lhs: FileItem, rhs: FileItem) -> Bool {
        let lhsComponents = lhs.relativePath.split(separator: "/").map(String.init)
        let rhsComponents = rhs.relativePath.split(separator: "/").map(String.init)

        let lhsParent = lhsComponents.dropLast().joined(separator: "/")
        let rhsParent = rhsComponents.dropLast().joined(separator: "/")

        if lhsParent != rhsParent {
            return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }

        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory && !rhs.isDirectory
        }

        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

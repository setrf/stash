import Foundation
import SwiftUI
import UniformTypeIdentifiers

final class FileDropDelegate: DropDelegate {
    private let viewModel: OverlayViewModel

    init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
        viewModel.isDragTarget = true
    }

    func dropExited(info: DropInfo) {
        viewModel.isDragTarget = false
    }

    func performDrop(info: DropInfo) -> Bool {
        viewModel.isDragTarget = false
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                defer { group.leave() }
                guard error == nil else { return }

                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                } else if let url = item as? URL {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) { [weak viewModel] in
            guard let viewModel else { return }
            viewModel.handleDroppedFiles(urls)
        }

        return true
    }
}

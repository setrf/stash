import Foundation

final class BackendClient {
    private let baseURL = URL(string: "http://127.0.0.1:8765")!
    private let projectId = "default"

    func registerAssets(urls: [URL]) {
        let endpoint = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("projects")
            .appendingPathComponent(projectId)
            .appendingPathComponent("assets")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = RegisterAssetsRequest(
            assets: urls.map { AssetPayload(kind: "file", pathOrUrl: $0.path) }
        )

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            print("Failed to encode asset payload: \(error)")
            return
        }

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                print("Asset upload failed: \(error)")
                return
            }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("Asset upload returned status: \(http.statusCode)")
            }
        }.resume()
    }
}

private struct RegisterAssetsRequest: Codable {
    let assets: [AssetPayload]
}

private struct AssetPayload: Codable {
    let kind: String
    let pathOrUrl: String

    enum CodingKeys: String, CodingKey {
        case kind
        case pathOrUrl = "path_or_url"
    }
}

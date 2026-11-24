import Foundation
import SwiftUI

/// Checks GitHub Releases for a newer build (CI tags them blendpaint-<build>).
@Observable
final class Updater {
    static let repo = "DEVINKoff/repo"
    static let sourceURL = "https://github.com/\(repo)/releases/latest/download/altstore-source.json"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    var latestBuild: Int?
    var latestNotes = ""
    var ipaURL: URL?
    var dismissed = false

    var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0 }
    var hasUpdate: Bool { (latestBuild ?? 0) > currentBuild && !dismissed }

    func check() {
        guard let url = URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String, tag.hasPrefix("blendpaint-"),
                  let n = Int(tag.dropFirst("blendpaint-".count)) else { return }
            let assets = obj["assets"] as? [[String: Any]] ?? []
            let ipa = assets.first { ($0["name"] as? String)?.hasSuffix(".ipa") == true }?["browser_download_url"] as? String
            let notes = obj["body"] as? String ?? ""
            DispatchQueue.main.async {
                withAnimation(.spring(duration: 0.4)) {
                    self?.latestBuild = n
                    self?.latestNotes = notes
                    self?.ipaURL = ipa.flatMap(URL.init(string:))
                }
            }
        }.resume()
    }

    static func sideStoreURL() -> URL? {
        let enc = sourceURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? sourceURL
        return URL(string: "sidestore://source?url=\(enc)")
    }

    static func altStoreURL() -> URL? {
        let enc = sourceURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? sourceURL
        return URL(string: "altstore://source?url=\(enc)")
    }
}

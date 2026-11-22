import Foundation
import Observation

/// `lib/events.ts`: the Hub's SSE stream (`GET /api/events`), reconnecting with backoff.
@MainActor
@Observable
final class HubEvents {
    static let shared = HubEvents()

    private(set) var connected = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var everOpened = false
    @ObservationIgnored private var handlers: [(HubEvent) -> Void] = []

    private init() {}

    func on(_ fn: @escaping (HubEvent) -> Void) { handlers.append(fn) }

    func start() {
        guard task == nil else { return }
        everOpened = false
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        connected = false
    }

    private func emit(_ e: HubEvent) { for h in handlers { h(e) } }

    private func run() async {
        var retry = 0
        while !Task.isCancelled {
            do {
                guard let url = HubClient.shared.url("/api/events") else { return }
                var req = URLRequest(url: url)
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.timeoutInterval = 90 // the Hub pings every 20 s
                let (bytes, response) = try await HubClient.shared.session.bytes(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    if (response as? HTTPURLResponse)?.statusCode == 401 { NotificationCenter.default.post(name: .hubUnauthorized, object: nil) }
                    throw URLError(.badServerResponse)
                }
                retry = 0
                connected = true
                if everOpened { emit(.reconnect) }
                everOpened = true
                var name = "message"
                var data = ""
                for try await line in bytes.lines {
                    if line.isEmpty {
                        dispatch(name, data)
                        name = "message"; data = ""
                    } else if line.hasPrefix("event:") {
                        // `lines` drops the blank line between events: a new `event:` closes the previous one
                        if !data.isEmpty { dispatch(name, data); data = "" }
                        name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        let chunk = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        data = data.isEmpty ? chunk : data + "\n" + chunk
                        // one-line JSON events: hand them over at once
                        if (try? JSONSerialization.jsonObject(with: Data(data.utf8))) != nil {
                            dispatch(name, data)
                            data = ""
                        }
                    }
                }
            } catch {
                if Task.isCancelled { break }
            }
            connected = false
            let delay = min(30.0, pow(2, Double(retry)))
            retry += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func dispatch(_ name: String, _ data: String) {
        guard !data.isEmpty else { return }
        let raw = Data(data.utf8)
        switch name {
        case "download":
            if let d = try? HubClient.shared.decodeValue(DownloadItemOut.self, from: raw) { emit(.download(d)) }
        case "library":
            struct L: Decodable { var kind: String? }
            emit(.library(kind: (try? HubClient.shared.decodeValue(L.self, from: raw))?.kind ?? "changed"))
        case "search_history":
            emit(.searchHistory)
        default:
            break
        }
    }
}

import SwiftUI

/// «Другой файл»: the files the sources have for the playing track (the Files search, by artist and title, editable);
/// a tap makes that file the track's from now on — played, and taken by its download.
struct PickFileSheet: View {
    let track: QueueTrack
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var files: [Candidate]?
    @State private var error: String?
    @State private var picking: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let info = player.info, player.track?.uid == track.uid {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform").foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Сейчас играет").font(.caption).foregroundStyle(.secondary)
                                Text([info.provider.map(providerName), info.bitrateKbps.map { "\(Int($0)) кбит/с" }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                    }
                } footer: {
                    Text("Выберите правильный файл — он будет играть и скачиваться для этого трека вместо найденного автоматически.")
                }
                if let error {
                    Text(error).foregroundStyle(.orange).font(.footnote)
                }
                if let files {
                    if files.isEmpty {
                        ContentUnavailableView("Ничего не нашлось", systemImage: "magnifyingglass", description: Text("Измените запрос"))
                    }
                    ForEach(files) { f in
                        Button { pick(f) } label: { row(f) }
                            .buttonStyle(.plain)
                            .disabled(picking != nil)
                    }
                } else if error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Исполнитель и название")
            .onSubmit(of: .search) { Task { await search() } }
            .navigationTitle("Другой файл")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .task {
                query = "\(track.artist) \(track.title)"
                await search()
            }
        }
        .presentationDetents([.large])
    }

    private func row(_ f: Candidate) -> some View {
        HStack(spacing: 12) {
            Cover(url: f.coverUrl, size: 44, corner: 6, symbol: "waveform")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(f.title ?? "Без названия").lineLimit(1)
                    if f.explicit == true { ExplicitBadge() }
                }
                Text(f.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Tag(text: providerName(f.provider))
                    if let d = f.durationS {
                        let off = track.durationS.map { abs($0 - d) > 6 } ?? false
                        Tag(text: Format.time(d), tint: off ? .orange : .secondary)
                    }
                    if let b = f.bitrateKbps { Tag(text: "\(Int(b)) кбит/с") }
                }
            }
            Spacer(minLength: 0)
            if picking == f.fileRef { ProgressView() } else { Image(systemName: "checkmark.circle").foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        files = nil
        error = nil
        do {
            let out = try await HubClient.shared.searchProviders(q, group: nil)
            withAnimation(.smooth) { files = (out.candidates ?? []).filter { $0.fileRef != nil } }
            if files?.isEmpty == true, let e = out.errors?.first { error = e }
        } catch {
            self.error = error.localizedDescription
            files = []
        }
    }

    private func pick(_ f: Candidate) {
        guard let file = f.fileRef else { return }
        picking = file
        Haptics.tap()
        Task {
            do {
                _ = try await HubClient.shared.pickFile(ref: track.ref, fileRef: file)
                Haptics.success()
                Toasts.success("Файл заменён")
                if player.track?.ref == track.ref { player.replayWithNewFile() }
                dismiss()
            } catch {
                Haptics.error()
                self.error = error.localizedDescription
            }
            picking = nil
        }
    }
}

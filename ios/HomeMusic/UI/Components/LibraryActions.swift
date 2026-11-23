import PhotosUI
import SwiftUI

/// What «Другой файл» works on: a streamed track (the listen pick changes) or a library song (it is downloaded
/// again with that file).
struct PickTarget: Identifiable, Hashable {
    var ref: String
    var artist: String
    var title: String
    var durationS: Double?
    /// set — a library song: the file is downloaded and replaces the old one
    var libraryId: String?
    var star = false
    var id: String { (libraryId ?? ref) + title }

    init(_ t: QueueTrack) {
        ref = t.ref
        artist = t.artist
        title = t.title
        durationS = t.durationS
    }

    init(library t: Track, liked: Bool) {
        ref = t.ref
        artist = t.artistLine
        title = t.title
        durationS = t.durationS
        libraryId = t.ndSongId
        star = liked
    }
}

/// The library song actions of the track menu (their sheets live at the top of the app).
@MainActor
@Observable
final class LibraryActions {
    static let shared = LibraryActions()
    var picking: PickTarget?
    /// the song whose album gets a picture from the photo library
    var photoFor: String?
    var photoItem: PhotosPickerItem?

    func betterCover(_ t: Track) {
        guard let id = t.ndSongId else { return }
        Haptics.tap()
        Toasts.info("Ищу обложку получше…")
        Task {
            do {
                try await HubClient.shared.refreshSongCover(ndSongId: id)
                Haptics.success()
                Toasts.success("Обложка обновлена")
                ImageCache.shared.removeAll()
                URLCache.shared.removeAllCachedResponses()
                Library.shared.invalidate()
            } catch {
                Toasts.error(error.localizedDescription)
            }
        }
    }

    func choosePhoto(_ t: Track) {
        guard let id = t.ndSongId else { return }
        photoItem = nil
        photoFor = id
    }

    /// The picture from the photo library, as a JPEG, onto the album.
    func uploadPhoto() {
        guard let id = photoFor, let item = photoItem else { return }
        photoFor = nil
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data),
                  let jpeg = img.preparingThumbnail(of: Self.fit(img.size, 1600))?.jpegData(compressionQuality: 0.9) ?? img.jpegData(compressionQuality: 0.9) else {
                Toasts.error("Не удалось открыть картинку")
                return
            }
            do {
                try await HubClient.shared.uploadSongCover(ndSongId: id, jpeg: jpeg)
                Haptics.success()
                Toasts.success("Обложка заменена")
                ImageCache.shared.removeAll()
                URLCache.shared.removeAllCachedResponses()
                Library.shared.invalidate()
            } catch {
                Toasts.error(error.localizedDescription)
            }
        }
    }

    func refresh(_ t: Track, liked: Bool) {
        guard let id = t.ndSongId else { return }
        Haptics.tap()
        Task {
            do {
                _ = try await HubClient.shared.refreshSong(ndSongId: id, candidate: nil, star: liked)
                Toasts.success("Трек скачивается заново — старый файл заменится, когда новый будет готов")
            } catch {
                Toasts.error(error.localizedDescription)
            }
        }
    }

    private static func fit(_ s: CGSize, _ m: CGFloat) -> CGSize {
        let k = min(1, m / max(s.width, s.height))
        return CGSize(width: s.width * k, height: s.height * k)
    }
}

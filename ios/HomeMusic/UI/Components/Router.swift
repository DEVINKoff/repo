import Observation
import SwiftUI

/// Where a screen can lead (each tab has its own stack).
enum Dest: Hashable {
    case catalogAlbum(String)
    case catalogArtist(String)
    case ndAlbum(String)
    case ndArtist(String)
    case playlist(id: String, name: String?)
    case mix(Int)
    case liked
    case playlists
    case ndAlbums
    case ndArtists
    case downloads
    case taste
    case web(path: String, title: String)
}

enum AppTab: Hashable { case home, library, more, search }

@MainActor
@Observable
final class Router {
    static let shared = Router()
    var tab: AppTab = .home
    var home: [Dest] = []
    var library: [Dest] = []
    var more: [Dest] = []
    var search: [Dest] = []

    /// «Загрузки» live in the library now (a toast's «Загрузки» goes there).
    func openDownloads() {
        AppModel.shared.playerOpen = false
        tab = .library
        if library.last != .downloads { library.append(.downloads) }
    }

    /// Opens a screen in the current tab (from the player: the sheet closes first).
    func go(_ d: Dest) {
        AppModel.shared.playerOpen = false
        switch tab {
        case .home: home.append(d)
        case .library: library.append(d)
        case .more: more.append(d)
        case .search: search.append(d)
        }
    }
}

extension View {
    /// Every screen a stack can show.
    func destinations() -> some View {
        navigationDestination(for: Dest.self) { d in
            switch d {
            case .catalogAlbum(let ref): CatalogAlbumView(ref: ref)
            case .catalogArtist(let ref): CatalogArtistView(ref: ref)
            case .ndAlbum(let id): NdAlbumView(id: id)
            case .ndArtist(let id): NdArtistView(id: id)
            case .playlist(let id, let name): PlaylistView(id: id, name: name)
            case .mix(let id): MixView(id: id)
            case .liked: LikedView()
            case .playlists: PlaylistsView()
            case .ndAlbums: NdAlbumsView()
            case .ndArtists: NdArtistsView()
            case .downloads: DownloadsView()
            case .taste: TasteOnboardingView()
            case .web(let path, let title): HubWebScreen(path: path, title: title)
            }
        }
    }

    /// Liquid Glass on iOS 26, a material on older systems.
    @ViewBuilder
    func glassCapsule(interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func glassCircle(interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.interactive(interactive), in: Circle())
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }

    @ViewBuilder
    func glassRect(_ radius: CGFloat = 22, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    /// Prominent glass button style on iOS 26, bordered prominent before it.
    @ViewBuilder
    func prominentButton() -> some View {
        if #available(iOS 26.0, *) { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.borderedProminent) }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(iOS 26.0, *) { self.buttonStyle(.glass) } else { self.buttonStyle(.bordered) }
    }
}

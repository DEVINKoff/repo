import Foundation

// Models of the Hub API (hub/API.md, web/src/api/types.ts). JSON keys are snake_case; the client decodes with
// `.convertFromSnakeCase`, so `nd_song_id` is `ndSongId` here. Optional wherever the Hub may omit or null a field.

// MARK: - Any JSON (target_data, generators, warnings…)

enum JSONValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    var string: String? { if case .string(let s) = self { return s } else { return nil } }
}

// MARK: - Auth

struct MeOut: Codable, Hashable, Sendable {
    var id: Int
    var username: String
    var isAdmin: Bool
    var publicMusicUrl: String?
    var publicHubUrl: String?
    var googleEmail: String?
    var email: String?
}

struct LoginIn: Codable, Sendable { var username: String; var password: String }
struct RegisterIn: Codable, Sendable { var code: String; var username: String; var password: String }

struct AuthOptionsOut: Codable, Sendable {
    var invites: Bool
    var emailSignup: Bool?
    var googleClientId: String?
    var musicUrl: String?
}

struct OkOut: Codable, Sendable { var ok: Bool? }

struct HealthOut: Codable, Sendable {
    var capabilities: [String]?
    var ok: Bool?
    var navidrome: Bool?
    var version: String?
}

// MARK: - Tracks (TrackOut, NdSongOut, WaveTrackOut, MixTrackOut, SmartRecOut in one)

struct Track: Codable, Hashable, Identifiable, Sendable {
    var ref: String
    var source: String?
    var title: String
    var artist: String
    var artists: [String]?
    var artistRef: String?
    var albumRef: String?
    var albumTitle: String?
    var albumArtist: String?
    var durationS: Double?
    var trackNo: Int?
    var discNo: Int?
    var isrc: String?
    var explicit: Bool?
    var releaseDate: String?
    var coverUrl: String?
    var coverSmallUrl: String?
    var previewUrl: String?
    // TrackOut
    var owned: Bool?
    var libraryTrackId: Int?
    var ndSongId: String?
    var downloading: Bool?
    var starPending: Bool?
    // NdSongOut
    var ndAlbumId: String?
    var ndArtistId: String?
    // Wave / mix / smart
    var generator: String?
    var generatorTitle: String?
    var familiar: Bool?
    var sim: Double?
    var position: Int?
    var score: Double?
    var after: String?
    var slot: Int?

    var id: String { ref }
    var isOwned: Bool { owned == true }
    /// «Artist, Artist» as the PWA shows it.
    var artistLine: String { (artists?.isEmpty == false) ? artists!.joined(separator: ", ") : artist }
    var year: Int? { releaseDate.flatMap { Int($0.prefix(4)) } }
}

struct LibTrackOut: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var ndSongId: String?
    var albumId: Int?
    var artist: String
    var title: String
    var album: String?
    var durationS: Double?
    var explicit: Bool?
    var year: Int?
}

// MARK: - Listening

struct ListenOut: Codable, Hashable, Sendable {
    var ref: String
    /// full: the file a download would take; preview: Deezer's 30 s preview; library: own file
    var kind: String
    var artist: String
    var title: String
    var durationS: Double?
    var provider: String?
    var bitrateKbps: Double?
    var pageUrl: String?
    var ndSongId: String?
    var streamUrl: String?
}

struct TrackMetadata: Codable, Hashable, Sendable {
    struct Artist: Codable, Hashable, Sendable { var name: String; var ref: String? }
    var title: String?
    var album: String?
    var artistCredit: String?
    var artists: [Artist]?
    var durationS: Double?
    var isrc: String?
    var year: Int?
}

struct PlayEventIn: Codable, Hashable, Sendable {
    var targetType: String?
    var ndAlbumId: String?
    var ndArtistId: String?
    var targetData: [String: JSONValue]?
    var revertsEventId: String?
    var eventId: String
    var ts: String
    var kind: String
    var ref: String?
    var ndSongId: String?
    var playbackId: String?
    var deviceId: String?
    var listenedMs: Int?
    var trackMetadata: TrackMetadata?
    var positionS: Double?
    var durationS: Double?
    var context: String?
    var client: String
    var launchId: String?
    var launchOrigin: String?
}

struct PlayEventsOut: Codable, Sendable {
    struct Rejected: Codable, Sendable { var index: Int; var eventId: String?; var detail: String }
    var accepted: Int
    var duplicates: Int
    var rejected: [Rejected]
}

// MARK: - Wave, smart shuffle, mixes

struct WaveSeedIn: Codable, Hashable, Sendable {
    var ref: String?
    var ndSongId: String?
    var artistRef: String?
    var ndArtistId: String?
    var byArtist: Bool?
}

struct WaveStartIn: Codable, Sendable {
    var seed: WaveSeedIn?
    var mode: String?
    var origin: String?
    var client: String?
    var restartOf: String?
}

struct WaveNextIn: Codable, Sendable { var played: [PlayEventIn]; var queued: [String] }

struct WaveOut: Codable, Sendable {
    struct Seed: Codable, Sendable { var ref: String?; var artistRef: String?; var ndArtistId: String?; var artist: String?; var title: String? }
    var sessionId: String
    var title: String
    var mode: String?
    var seed: Seed?
    var tracks: [Track]
    var pending: Bool
}

struct SmartStartIn: Codable, Sendable {
    var context: String
    var songs: [String]
    var current: String?
    var title: String?
    var origin: String?
    var client: String?
}

struct SmartNextIn: Codable, Sendable { var played: [PlayEventIn]; var at: String? }
struct SmartTargetIn: Codable, Sendable { var ref: String?; var ndSongId: String? }

struct SmartOut: Codable, Sendable {
    var sessionId: String
    var context: String
    var title: String?
    var own: [String]
    var recs: [Track]
    var pending: Bool
    var ownPerRec: Int?
}

struct SmartAddOut: Codable, Sendable { var ok: Bool; var status: String; var playlistId: String? }

struct MixSettingsOut: Codable, Sendable {
    struct Artist: Codable, Hashable, Sendable { var ref: String; var name: String }
    var mode: String
    var mixHour: Int
    var timezone: String?
    var nextBuildAt: String?
    var ndPlaylistId: String?
    var artists: [Artist]?
}

struct MixSettingsIn: Codable, Sendable { var mode: String?; var mixHour: Int? }

struct MixOut: Codable, Identifiable, Sendable {
    var id: Int
    var title: String
    var description: String?
    var mode: String?
    var modeTitle: String?
    var createdAt: String?
    var ndPlaylistId: String?
    var ready: Int?
    var total: Int?
    var tracks: [Track]
}

struct MixTodayOut: Codable, Sendable {
    var mix: MixOut?
    var building: Bool
    var settings: MixSettingsOut?
    var onboarding: Bool
}

struct TasteOnboardingOut: Codable, Sendable {
    struct Picked: Codable, Hashable, Sendable { var ref: String; var name: String }
    var needed: Bool
    var selected: [Picked]
    var suggestions: [CatalogArtist]
}

// MARK: - Catalog

struct CatalogArtist: Codable, Hashable, Identifiable, Sendable {
    var ref: String
    var source: String?
    var name: String
    var pictureUrl: String?
    var pictureSmallUrl: String?
    var nbAlbums: Int?
    var nbFans: Int?
    var id: String { ref }
}

struct AlbumOut: Codable, Hashable, Identifiable, Sendable {
    var ref: String
    var source: String?
    var title: String
    var artist: String
    var artistRef: String?
    var recordType: String?
    var releaseDate: String?
    var year: Int?
    var coverUrl: String?
    var coverSmallUrl: String?
    var nbTracks: Int?
    var explicit: Bool?
    var genre: String?
    var ownedStatus: String?
    var ownedCount: Int?
    var tracks: [Track]?
    var id: String { ref }
    var displayYear: Int? { year ?? releaseDate.flatMap { Int($0.prefix(4)) } }
}

struct ArtistPageOut: Codable, Sendable {
    var artist: CatalogArtist
    var topTracks: [Track]
    var albums: [AlbumOut]
    var singles: [AlbumOut]
    var compilations: [AlbumOut]
}

struct SearchOut: Codable, Sendable {
    var library: [LibTrackOut]
    var artists: [CatalogArtist]
    var albums: [AlbumOut]
    var tracks: [Track]
    var tracksNext: Int?
    var errors: [String]?
}

struct SearchTracksOut: Codable, Sendable { var tracks: [Track]; var nextOffset: Int? }
struct SearchHistoryOut: Codable, Sendable { var queries: [String] }

/// A downloadable file of a provider (`/api/search/providers`, Files tab).
struct Candidate: Codable, Hashable, Identifiable, Sendable {
    var provider: String
    var providerId: String?
    var artist: String?
    var title: String?
    var durationS: Double?
    var bitrateKbps: Double?
    var explicit: Bool?
    var uploadDate: String?
    var pageUrl: String?
    var coverUrl: String?
    var album: String?
    var extra: [String: JSONValue]?
    var id: String { "\(provider):\(providerId ?? pageUrl ?? title ?? "")" }
    /// The Hub remembers every file it returns: `file:<provider>:<provider_id>`.
    var fileRef: String? { providerId.map { "file:\(provider):\($0)" } }
    var isReupload: Bool { if case .bool(true)? = extra?["reupload"] { return true } else { return false } }
    var uncensored: Bool? { if case .bool(let b)? = extra?["uncensored"] { return b } else { return nil } }
    var channel: String? { extra?["channel"]?.string }
}

struct ProviderSearchOut: Codable, Sendable {
    var candidates: [Candidate]?
    var errors: [String]?
}

// MARK: - Downloads

struct DownloadItemOut: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var batchId: Int?
    var status: String
    var progress: Double?
    var artist: String
    var title: String
    var album: String?
    var provider: String?
    var error: String?
    var ndSongId: String?
    var playlistId: String?
    var trackRef: String?
    var star: Bool?
    var liked: Bool?
    var importId: Int?
    var createdAt: String?
    var updatedAt: String?

    var isActive: Bool { ["queued", "searching", "downloading", "tagging", "importing"].contains(status) }
}

struct DownloadIn: Codable, Sendable {
    var trackRefs: [String]?
    var albumRef: String?
    var artistRef: String?
    var recordTypes: [String]?
    var playlistId: String?
    var newPlaylistName: String?
    var force: Bool?
    var star: Bool?
}

struct DownloadBatchOut: Codable, Sendable {
    var batchId: Int?
    var queued: Int
    var alreadyOwned: Int
    var playlistId: String?
    var expanding: Bool?
}

struct ClearOut: Codable, Sendable { var removed: Int? }

// MARK: - Favorites, dislikes

struct FavoriteTarget: Codable, Hashable, Sendable {
    var targetType: String
    var ref: String?
    var ndSongId: String?
    var ndAlbumId: String?
    var ndArtistId: String?
    var targetData: [String: JSONValue]?
}

struct StarIn: Codable, Sendable {
    var targets: [FavoriteTarget]?
    var eventId: String?
    var ts: String?
    var client: String?
    var context: String?
    var songIds: [String]?
    var albumIds: [String]?
    var artistIds: [String]?
    var refs: [String]?
    var unstar: Bool?
}

struct StarOut: Codable, Sendable { var ok: Bool?; var eventIds: [String]? }

struct FavoriteSubject: Codable, Sendable {
    var targetType: String
    var key: String?
    var ref: String?
    var ndId: String?
    var liked: Bool
    var eventId: String?
    var aliases: [String]?
    var provenance: String?
}

struct StarredOut: Codable, Sendable {
    var songIds: [String]
    var albumIds: [String]
    var refs: [String]?
    var artistIds: [String]?
    var subjects: [FavoriteSubject]?
}

struct DislikeOut: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var ref: String?
    var ndSongId: String?
    var artistRef: String?
    var artist: String?
    var title: String?
    var source: String?
    var createdAt: String?
}

struct DislikeIn: Codable, Sendable {
    var ref: String?
    var ndSongId: String?
    var artistRef: String?
    var artist: String?
    var title: String?
    var context: String?
    var client: String?
}

struct RemovedOut: Codable, Sendable { var removed: Int? }

// MARK: - Navidrome library through the Hub

struct NdAlbumOut: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var artist: String
    var artistId: String?
    var year: Int?
    var songCount: Int?
    var durationS: Double?
    var coverUrl: String?
    var starred: Bool?
    var tracks: [Track]?
}

struct NdArtistOut: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var albumCount: Int?
    var coverUrl: String?
    var starred: Bool?
}

struct NdHomeOut: Codable, Sendable {
    var recent: [NdAlbumOut]
    var frequent: [NdAlbumOut]
    var newest: [NdAlbumOut]
    var starred: [NdAlbumOut]
    var radio: [NdArtistOut]
}

struct NdLikedOut: Codable, Sendable {
    var songs: [Track]
    var albums: [NdAlbumOut]
    var artists: [NdArtistOut]
}

struct NdArtistPageOut: Codable, Sendable { var artist: NdArtistOut; var albums: [NdAlbumOut] }

struct PlaylistOut: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var songCount: Int?
    var durationS: Double?
    var coverArt: String?
}

struct PlaylistPageOut: Codable, Sendable {
    var id: String
    var name: String
    var songCount: Int?
    var durationS: Double?
    var coverArt: String?
    var tracks: [Track]
}

struct PlaylistCreateIn: Codable, Sendable { var name: String }
struct PlaylistAddIn: Codable, Sendable { var songIds: [String]? }
struct PlaylistRemoveIn: Codable, Sendable { var indexes: [Int] }

// MARK: - The player's queue entry (web/src/lib/listen.ts `ListenTrack`)

struct QueueTrack: Codable, Hashable, Identifiable, Sendable {
    struct Rec: Codable, Hashable, Sendable { var label: String; var session: String }
    struct Artist: Codable, Hashable, Sendable { var name: String; var ref: String? }

    /// Own identity: the same track may stand in the queue twice (the PWA relies on object identity).
    var uid = UUID()
    var ref: String
    var ndSongId: String?
    var rec: Rec?
    var title: String
    var artist: String
    var coverUrl: String?
    var coverSmallUrl: String?
    var albumRef: String?
    var artistRef: String?
    var artists: [Artist]?
    var album: String?
    var isrc: String?
    var year: Int?
    var durationS: Double?

    var id: UUID { uid }

    /// `idOf`: the id the Hub knows a playlist's track by — its Navidrome song, else the catalog ref.
    var hubId: String { (ndSongId?.isEmpty == false) ? ndSongId! : ref }

    func copy() -> QueueTrack { var t = self; t.uid = UUID(); return t }

    /// `listenTrack` of components/catalog.tsx (`withSong`) and of lib/wave.ts (without the song id).
    init(_ t: Track, withSong: Bool = true, rec: Rec? = nil) {
        ref = t.ref
        ndSongId = withSong ? t.ndSongId : nil
        self.rec = rec
        title = t.title
        artist = t.artistLine
        coverUrl = t.coverUrl
        coverSmallUrl = t.coverSmallUrl
        albumRef = t.albumRef
        artistRef = t.artistRef
        let names = (t.artists?.isEmpty == false) ? t.artists! : [t.artist]
        artists = names.map { name in
            Artist(name: name, ref: (t.artists?.isEmpty == false && name == t.artist) ? t.artistRef : nil)
        }
        album = t.albumTitle
        isrc = t.isrc
        year = t.year
        durationS = t.durationS
    }

    init(ref: String, ndSongId: String? = nil, title: String, artist: String, coverUrl: String? = nil,
         album: String? = nil, durationS: Double? = nil) {
        self.ref = ref
        self.ndSongId = ndSongId
        self.title = title
        self.artist = artist
        self.coverUrl = coverUrl
        self.album = album
        self.durationS = durationS
    }
}

// MARK: - SSE events

enum HubEvent: Sendable {
    case download(DownloadItemOut)
    case library(kind: String)
    case searchHistory
    case reconnect
}

struct MotionOut: Codable, Sendable { var url: String? }

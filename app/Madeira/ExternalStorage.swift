// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

// An external drive (a USB or Thunderbolt disk, an SD card) as the place a
// Steam game is installed (docs/EXTERNAL_STORAGE.md). Foundation only.
//
// The person picks a folder on the drive once. Madeira keeps a bookmark to it
// and opens its security scope for the life of the process, so Wine and the
// downloader can use plain paths under it. A game's install folder,
//     C:\Program Files (x86)\Steam\steamapps\common\<installdir>
// then becomes a symbolic link to <picked folder>/Madeira Games/<installdir>.
// Everything else stays where it was: the install record (`appmanifest_<id>.acf`),
// the resume journals and Steam's own files are small and stay on the iPad, and
// Madeira Dock, the downloader and Valve's client all keep reading one library
// folder. Only the game's own files live on the drive.
//
// The link holds an absolute path, and iOS may mount the same drive at another
// path next time, so every activation repoints the links that name a
// "Madeira Games" folder (relink).

enum ExternalStorage {
    /// The folder created inside the folder the person picked; it holds one folder per game.
    static let gamesFolderName = "Madeira Games"
    static let bookmarkKey = "madeira.externalStorage.bookmark"
    static let installKey = "madeira.externalStorage.install"

    enum Failure: Error, LocalizedError {
        case notChosen
        case notReachable
        case notWritable
        case occupied(String)
        case link(String)

        var errorDescription: String? {
            switch self {
            case .notChosen: return "No external drive folder is chosen. Choose one in the game's install settings."
            case .notReachable: return "The external drive is not connected. Connect it and try again."
            case .notWritable: return "Madeira cannot write to that folder. Choose a folder on a drive formatted as exFAT or APFS that is not read-only."
            case .occupied(let name): return "The install folder \"\(name)\" is already linked somewhere else."
            case .link(let reason): return "The game folder on the drive could not be linked: \(reason)"
            }
        }
    }

    // MARK: Choice

    /// Whether a folder on a drive has been chosen.
    static var hasChoice: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    /// Whether new installs go to the drive. Only meaningful once a folder is chosen.
    static var installsExternally: Bool {
        get { hasChoice && UserDefaults.standard.bool(forKey: installKey) }
        set { UserDefaults.standard.set(newValue, forKey: installKey) }
    }

    /// Forgets the chosen folder. Games already installed there keep their links
    /// and need the drive connected again to start.
    static func forget() {
        lock.lock(); defer { lock.unlock() }
        closeScopeLocked()
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.set(false, forKey: installKey)
    }

    // MARK: Access

    private static let lock = NSLock()
    private static var scoped: URL?        // the picked folder, while its security scope is open
    private static var scopeOpened = false // startAccessingSecurityScopedResource returned true for it

    private static func startScope(_ url: URL) -> Bool {
        #if os(iOS) || os(macOS) || os(visionOS)
        return url.startAccessingSecurityScopedResource()
        #else
        return false
        #endif
    }

    private static func stopScope(_ url: URL) {
        #if os(iOS) || os(macOS) || os(visionOS)
        url.stopAccessingSecurityScopedResource()
        #endif
    }

    private static func closeScopeLocked() {
        if let scoped, scopeOpened { stopScope(scoped) }
        scoped = nil
        scopeOpened = false
    }

    private static func bookmark(for url: URL) -> Data? {
        #if os(iOS) || os(macOS) || os(visionOS)
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return nil
        #endif
    }

    private static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        #if os(iOS) || os(macOS) || os(visionOS)
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
        #else
        return nil
        #endif
    }

    /// `<picked>/Madeira Games` when it exists as a folder.
    private static func gamesFolder(in picked: URL) -> URL? {
        let games = picked.appendingPathComponent(gamesFolderName, isDirectory: true)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: games.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        return games
    }

    /// Remembers a folder the person picked with the document picker, checks that
    /// games can be written there, and keeps its security scope open.
    /// Returns the games folder (`<picked>/Madeira Games`).
    @discardableResult
    static func choose(_ picked: URL) throws -> URL {
        let opened = startScope(picked)
        var keep = false
        defer { if opened && !keep { stopScope(picked) } }
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: picked.path, isDirectory: &isFolder), isFolder.boolValue else { throw Failure.notReachable }
        let games = picked.appendingPathComponent(gamesFolderName, isDirectory: true)
        do { try fm.createDirectory(at: games, withIntermediateDirectories: true) } catch { throw Failure.notWritable }
        let probe = games.appendingPathComponent(".madeira-write-test")
        guard fm.createFile(atPath: probe.path, contents: Data("ok".utf8)) else { throw Failure.notWritable }
        try? fm.removeItem(at: probe)
        guard let data = bookmark(for: picked) else { throw Failure.notWritable }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        lock.lock()
        closeScopeLocked()
        scoped = picked
        scopeOpened = opened
        lock.unlock()
        keep = true
        return games
    }

    /// Opens the chosen folder's security scope (once per run; later calls reuse it)
    /// and returns its games folder, or nil when no folder is chosen or the drive
    /// is not connected. With `common` (the library's `steamapps/common`), the
    /// links that point into a games folder are repointed at where the drive is
    /// mounted now. Safe to call from any thread, as often as needed.
    @discardableResult
    static func activate(repairingLinksIn common: URL? = nil) -> URL? {
        lock.lock(); defer { lock.unlock() }
        var games: URL?
        if let scoped, let current = gamesFolder(in: scoped) {
            games = current
        } else if let data = UserDefaults.standard.data(forKey: bookmarkKey), let resolved = resolve(data) {
            let opened = startScope(resolved.url)
            closeScopeLocked()
            scoped = resolved.url
            scopeOpened = opened
            if resolved.stale, let fresh = bookmark(for: resolved.url) { UserDefaults.standard.set(fresh, forKey: bookmarkKey) }
            games = gamesFolder(in: resolved.url)
        }
        if let games, let common { relink(common: common, games: games) }
        return games
    }

    /// The games folder when the drive is connected, without opening anything.
    static var gamesFolderIfReachable: URL? {
        lock.lock(); defer { lock.unlock() }
        guard let scoped else { return nil }
        return gamesFolder(in: scoped)
    }

    // MARK: Install folders

    /// Makes `common/<folderName>` a link to a folder of that name on the drive,
    /// creating the folder there. An install that is already on this iPad
    /// (a folder with files in it) is left alone, so an update or repair of a
    /// game installed before the drive was chosen keeps working. Throws when the
    /// drive is not connected, so an install never silently fills the iPad instead.
    static func prepare(folderName: String, common: URL) throws {
        guard hasChoice else { throw Failure.notChosen }
        guard let games = activate(repairingLinksIn: common) else { throw Failure.notReachable }
        try link(folderName: folderName, common: common, games: games)
    }

    /// The linking step of `prepare`, given the games folder.
    static func link(folderName: String, common: URL, games: URL) throws {
        let fm = FileManager.default
        let linkURL = common.appendingPathComponent(folderName, isDirectory: true)
        let target = games.appendingPathComponent(folderName, isDirectory: true)
        if let existing = try? fm.destinationOfSymbolicLink(atPath: linkURL.path) {
            if samePath(existing, target.path) {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                return
            }
            // Ours to repoint only when it names a games folder; anything else is not Madeira's link.
            guard URL(fileURLWithPath: existing).deletingLastPathComponent().lastPathComponent == gamesFolderName else {
                throw Failure.occupied(folderName)
            }
            try? fm.removeItem(at: linkURL)
        } else if fm.fileExists(atPath: linkURL.path) {
            // A real folder: an install on this iPad stays here; an empty one (a cancelled install) is replaced.
            if ((try? fm.contentsOfDirectory(atPath: linkURL.path)) ?? ["x"]).isEmpty {
                try? fm.removeItem(at: linkURL)
            } else {
                return
            }
        }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try fm.createDirectory(at: common, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: target.path)
        } catch {
            throw Failure.link(error.localizedDescription)
        }
    }

    /// Repoints every link in `common` that names a folder inside a "Madeira Games"
    /// folder at `games`, for a drive that came back at another mount path.
    static func relink(common: URL, games: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: common.path)) ?? [] {
            let link = common.appendingPathComponent(name)
            guard let existing = try? fm.destinationOfSymbolicLink(atPath: link.path),
                  URL(fileURLWithPath: existing).deletingLastPathComponent().lastPathComponent == gamesFolderName else { continue }
            let target = games.appendingPathComponent(URL(fileURLWithPath: existing).lastPathComponent, isDirectory: true)
            guard !samePath(existing, target.path), fm.fileExists(atPath: target.path) else { continue }
            try? fm.removeItem(at: link)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        }
    }

    /// Where `common/<folderName>` really is: the folder a Madeira link points to, or nil
    /// when it is not a link of ours.
    static func externalFolder(folderName: String, common: URL) -> URL? {
        let link = common.appendingPathComponent(folderName, isDirectory: true)
        guard let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
              URL(fileURLWithPath: existing).deletingLastPathComponent().lastPathComponent == gamesFolderName else { return nil }
        return URL(fileURLWithPath: existing)
    }

    private static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    // MARK: The drive

    /// The drive's name and free bytes, for the install settings.
    static func driveInfo() -> (name: String?, free: Int64?) {
        lock.lock(); defer { lock.unlock() }
        guard let scoped, let values = try? scoped.resourceValues(forKeys: [
            .volumeNameKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) else { return (nil, nil) }
        let free = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map { Int64($0) }
        return (values.volumeName, free)
    }
}

import Foundation
import SwiftUI
import CryptoKit
import ImageIO
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// Exercise pictures, downloaded once and kept on the device (Caches/ExerciseImages), so the
/// animations also work in a gym without signal. Workouts prefetch their pictures when they start.
///
/// * Disk reads and decoding never run on the main actor; pictures are decoded with ImageIO,
///   downsampled to the size they are shown at (points × screen scale).
/// * Decoded pictures stay in an `NSCache` keyed by URL and pixel size, with count and memory limits.
/// * URLs that fail are remembered for the session (broken links aren't retried on every scroll;
///   network errors are retried after a few minutes).
/// * The folder is pruned (oldest first) when it grows beyond ~100 MB.
actor ImageCache {
    static let shared = ImageCache()

    /// Caches/ExerciseImages, created once.
    static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = caches.appendingPathComponent("ExerciseImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static let memory: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private static let maxDiskBytes = 100 * 1024 * 1024
    private static let pruneTargetBytes = 70 * 1024 * 1024

    private var decoding: [String: Task<PlatformImage?, Never>] = [:]
    private var downloads: [URL: Task<DownloadResult, Never>] = [:]
    /// Broken URLs (HTTP errors, not an image): skipped for the rest of the session.
    private var broken: Set<URL> = []
    /// Network failures: retried after `retryAfter`.
    private var unreachable: [URL: Date] = [:]
    private static let retryAfter: TimeInterval = 180
    private var bytesSincePrune = 0
    private var didPruneThisSession = false

    private enum DownloadResult: Sendable {
        case saved(Int)
        case broken
        case unreachable
    }

    // MARK: Memory

    nonisolated private static func key(_ url: URL, pixels: Int) -> NSString {
        "\(url.absoluteString)#\(pixels)" as NSString
    }

    /// A decoded picture already in memory – never touches the disk, safe to call from a view.
    nonisolated func memoryImage(_ url: URL, maxPixelSize: Int) -> PlatformImage? {
        Self.memory.object(forKey: Self.key(url, pixels: maxPixelSize))
    }

    // MARK: Loading

    /// The picture at `url`, downsampled so its longer side has at most `maxPixelSize` pixels
    /// (memory → disk → network).
    func image(for url: URL, maxPixelSize: Int) async -> PlatformImage? {
        let key = Self.key(url, pixels: maxPixelSize)
        if let hit = Self.memory.object(forKey: key) { return hit }
        if let task = decoding[key as String] { return await task.value }
        let task = Task<PlatformImage?, Never> {
            guard let file = await self.fileOnDisk(for: url) else { return nil }
            guard let image = await Self.decode(file: file, maxPixelSize: maxPixelSize) else { return nil }
            Self.memory.setObject(image.image, forKey: key, cost: image.cost)
            return image.image
        }
        decoding[key as String] = task
        let image = await task.value
        decoding[key as String] = nil
        return image
    }

    /// Downloads pictures to the disk cache without decoding them (workouts call this on start).
    func prefetch(_ urls: [URL]) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls.prefix(80) {
                group.addTask { _ = await self.fileOnDisk(for: url) }
            }
        }
    }

    /// The cached file for `url`, downloading it first if needed; nil when it can't be had.
    private func fileOnDisk(for url: URL) async -> URL? {
        let file = Self.file(for: url)
        if await Self.exists(file) { return file }
        if broken.contains(url) { return nil }
        if let failedAt = unreachable[url], Date().timeIntervalSince(failedAt) < Self.retryAfter { return nil }
        let task: Task<DownloadResult, Never>
        if let running = downloads[url] {
            task = running
        } else {
            task = Task.detached(priority: .utility) { await Self.download(url, to: file) }
            downloads[url] = task
        }
        let result = await task.value
        downloads[url] = nil
        switch result {
        case .saved(let bytes):
            unreachable[url] = nil
            bytesSincePrune += bytes
            if !didPruneThisSession || bytesSincePrune > 10 * 1024 * 1024 {
                didPruneThisSession = true
                bytesSincePrune = 0
                Task.detached(priority: .background) { Self.pruneIfNeeded() }
            }
            return file
        case .broken:
            broken.insert(url)
            return nil
        case .unreachable:
            unreachable[url] = Date()
            return nil
        }
    }

    // MARK: Off-actor work

    nonisolated private static func exists(_ file: URL) async -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    nonisolated private static func download(_ url: URL, to file: URL) async -> DownloadResult {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else { return .broken }
            try data.write(to: file, options: .atomic)
            return .saved(data.count)
        } catch {
            return .unreachable
        }
    }

    /// Reads and decodes a file with ImageIO, downsampled (and with its orientation applied).
    nonisolated private static func decode(file: URL, maxPixelSize: Int) async -> (image: PlatformImage, cost: Int)? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, maxPixelSize),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let cost = cgImage.bytesPerRow * cgImage.height
        #if os(iOS)
        return (UIImage(cgImage: cgImage), cost)
        #else
        return (NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)), cost)
        #endif
    }

    /// Deletes the least recently used pictures when the folder is above ~100 MB.
    nonisolated private static func pruneIfNeeded() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, size: Int, used: Date)] = files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            let used = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            return (file, values.fileSize ?? 0, used)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxDiskBytes else { return }
        entries.sort { $0.used < $1.used }
        for entry in entries where total > pruneTargetBytes {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    nonisolated static func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(digest.prefix(32)) + "." + (url.pathExtension.isEmpty ? "img" : url.pathExtension))
    }
}

/// An exercise picture from the offline cache (downloaded once), decoded at the size it is shown.
struct CachedImage<Placeholder: View>: View {
    let url: URL
    var contentMode: ContentMode = .fit
    @ViewBuilder var placeholder: () -> Placeholder
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: PlatformImage?
    @State private var shownURL: URL?
    /// The longer side in pixels the picture is needed at (0 until laid out).
    @State private var pixels = 0

    private struct LoadKey: Hashable {
        let url: URL
        let pixels: Int
    }

    var body: some View {
        Group {
            if let image {
                #if os(iOS)
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                #else
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
                #endif
            } else {
                placeholder()
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            // Filling a frame needs a little more than its longer side; round up so small layout
            // changes don't decode the picture again.
            let side = max(size.width, size.height) * displayScale * (contentMode == .fill ? 1.4 : 1)
            let bucket = Int((side / 64).rounded(.up)) * 64
            if bucket > 0 && bucket != pixels { pixels = min(2048, bucket) }
        }
        .task(id: LoadKey(url: url, pixels: pixels)) {
            if shownURL != url {
                image = nil
                shownURL = url
            }
            guard pixels > 0 else { return }
            if let ready = ImageCache.shared.memoryImage(url, maxPixelSize: pixels) {
                image = ready
                return
            }
            let loaded = await ImageCache.shared.image(for: url, maxPixelSize: pixels)
            guard !Task.isCancelled, let loaded else { return }
            if image == nil && !reduceMotion {
                withAnimation(.easeIn(duration: 0.2)) { image = loaded }
            } else {
                image = loaded
            }
        }
    }
}

import Foundation
import SwiftUI
import CryptoKit
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// Exercise pictures, downloaded once and kept on the device (Caches/ExerciseImages), so the
/// animations also work in a gym without signal. Workouts prefetch their pictures when they start.
actor ImageCache {
    static let shared = ImageCache()

    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]

    nonisolated func cached(_ url: URL) -> PlatformImage? {
        if let image = memoryImage(url) { return image }
        guard let data = try? Data(contentsOf: Self.file(for: url)), let image = PlatformImage(data: data) else { return nil }
        return image
    }

    nonisolated private func memoryImage(_ url: URL) -> PlatformImage? {
        // NSCache is thread-safe.
        unsafeMemory.object(forKey: url as NSURL)
    }

    nonisolated private var unsafeMemory: NSCache<NSURL, PlatformImage> { Self.sharedMemory }
    private static let sharedMemory = NSCache<NSURL, PlatformImage>()

    func image(for url: URL) async -> PlatformImage? {
        if let image = cached(url) {
            Self.sharedMemory.setObject(image, forKey: url as NSURL)
            return image
        }
        if let task = inFlight[url] { return await task.value }
        let task = Task<PlatformImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, let image = PlatformImage(data: data) else { return nil }
            try? data.write(to: Self.file(for: url), options: .atomic)
            Self.sharedMemory.setObject(image, forKey: url as NSURL)
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        return image
    }

    func prefetch(_ urls: [URL]) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls.prefix(80) {
                group.addTask { _ = await self.image(for: url) }
            }
        }
    }

    nonisolated static func file(for url: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = caches.appendingPathComponent("ExerciseImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(digest.prefix(32)) + "." + (url.pathExtension.isEmpty ? "img" : url.pathExtension))
    }
}

/// An exercise picture from the offline cache (downloaded once).
struct CachedImage<Placeholder: View>: View {
    let url: URL
    var contentMode: ContentMode = .fit
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: PlatformImage?

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
        .task(id: url) {
            if let ready = ImageCache.shared.cached(url) {
                image = ready
            } else {
                let loaded = await ImageCache.shared.image(for: url)
                withAnimation(.easeIn(duration: 0.2)) { image = loaded }
            }
        }
    }
}

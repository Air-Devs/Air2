//
//  RemoteImageView.swift
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Mapping: A2RemoteImageView (ObjC UIView) -> RemoteImageView (SwiftUI) +
//  A2RemoteImageLoader + A2RemoteImageCache.
//
//  Cache policy is identical to the ObjC original: one process-wide NSCache
//  (cost = decoded pixels x 4, soft cap 64MB) over a Caches/A2RemoteImages
//  disk tier, with ImageIO downsampling so a large source is never decoded at
//  full size. Disk names are a stable hash of the URL, and every load carries a
//  token so a reused row can never show a stale callback's image.
//
//  Disk cache lives under NSCachesDirectory rather than Core/Path on purpose:
//  Core/Path owns semantic, migratable game data; image cache is disposable UI
//  scratch the system may purge at any time.
//

import SwiftUI
import UIKit
import CryptoKit

// MARK: - Cache (memory + disk + downsample)

enum A2RemoteImageCache {
    /// Process-wide decoded-image cache, purged automatically under memory pressure.
    private static let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Caches/A2RemoteImages, created on first access.
    private static let directory: String = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("A2RemoteImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }()

    /// Decoding runs off the main thread so scrolling never stalls.
    private static let workQueue = DispatchQueue(
        label: "dev.airdevs.air2.remoteimage",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func memoryImage(forKey key: String) -> UIImage? {
        memoryCache.object(forKey: key as NSString)
    }

    static func store(_ image: UIImage, forKey key: String) {
        let pixels = image.cgImage.map { $0.width * $0.height } ?? 0
        memoryCache.setObject(image, forKey: key as NSString, cost: pixels * 4)
    }

    /// Disk filename: stable hash of the URL. Cross-process stable, unlike hashValue.
    private static func diskPath(for urlString: String) -> String {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory + "/" + hex
    }

    /// Disk tier first, then network; decoded by ImageIO downsampling.
    static func image(for urlString: String, maxPixel: CGFloat) async -> UIImage? {
        let path = diskPath(for: urlString)

        if let data = FileManager.default.contents(atPath: path),
           let image = await decode(data, maxPixel: maxPixel) {
            store(image, forKey: urlString)
            return image
        }

        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              !data.isEmpty,
              let image = await decode(data, maxPixel: maxPixel) else {
            return nil
        }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        store(image, forKey: urlString)
        return image
    }

    private static func decode(_ data: Data, maxPixel: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            workQueue.async {
                continuation.resume(returning: downsample(data, maxPixel: maxPixel))
            }
        }
    }

    /// Thumbnail-first decode: never pulls the full-size bitmap into memory.
    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1),
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: thumb)
    }
}

// MARK: - Loader (drives the phase, cancels stale work)

/// Owns one remote image request. The view only renders `phase`; all cache and
/// network work stays here. Every `load` bumps a token so an in-flight callback
/// from a previous URL can never overwrite the current one (row reuse).
@MainActor
final class A2RemoteImageLoader: ObservableObject {
    @Published private(set) var phase: A2RemotePhase = .empty

    private var token = 0
    private var inFlight: Task<Void, Never>?
    private var lastRequest: (urlString: String, maxPixel: CGFloat)?

    func load(urlString: String?, maxPixel: CGFloat) {
        token &+= 1
        let current = token
        inFlight?.cancel()
        inFlight = nil

        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else {
            phase = .empty
            return
        }
        lastRequest = (urlString, maxPixel)

        // Memory hit paints immediately — no placeholder flash.
        if let cached = A2RemoteImageCache.memoryImage(forKey: urlString) {
            phase = .loaded(url, cached)
            return
        }

        phase = .loading(url)
        inFlight = Task { [weak self] in
            let image = await A2RemoteImageCache.image(for: urlString, maxPixel: maxPixel)
            guard !Task.isCancelled, let self, self.token == current else { return }
            if let image {
                self.phase = .loaded(url, image)
            } else {
                A2ComponentLog("RemoteImageView: 远程图片加载失败 \(urlString)")
                self.phase = .failed(url)
            }
        }
    }

    func retry() {
        guard let last = lastRequest else { return }
        load(urlString: last.urlString, maxPixel: last.maxPixel)
    }

    func cancel() {
        token &+= 1
        inFlight?.cancel()
        inFlight = nil
    }
}

// MARK: - View

/// Remote icon/cover with placeholder, failure retry and a fixed square frame.
struct RemoteImageView: View {
    let urlString: String?
    var size: CGFloat
    var cornerRadius: CGFloat = A2RadiusM

    @StateObject private var loader = A2RemoteImageLoader()
    @Environment(\.displayScale) private var displayScale

    private var maxPixel: CGFloat { max(size, 1) * displayScale }

    var body: some View {
        Group {
            switch loader.phase {
            case .loaded(_, let image):
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failed:
                Button { loader.retry() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.cOnSurfaceVariant)
                        .frame(width: size, height: size)
                        .background(Color.cSurfaceContainerHigh)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reload image")
            case .empty, .loading:
                Color.cSurfaceContainerHigh
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: urlString) {
            loader.load(urlString: urlString, maxPixel: maxPixel)
        }
    }
}

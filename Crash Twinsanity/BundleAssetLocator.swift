//
//  BundleAssetLocator.swift
//  Crash Bandicoot Game
//
//  Created on 08/07/2026.
//

import Foundation

/// Locates loose resource files in the app bundle without assuming a fixed
/// folder layout. Xcode's file-system-synchronized groups can either
/// preserve or flatten subdirectories when copying resources, so this
/// tries the expected path first and falls back to a recursive bundle scan.
enum BundleAssetLocator {

    private static var resourceIndex: [String: URL] = {
        buildIndex()
    }()

    static func find(fileName: String, extension ext: String, preferredSubdirectory: String? = nil) -> URL? {
        if let subdirectory = preferredSubdirectory,
           let url = Bundle.main.url(forResource: fileName, withExtension: ext, subdirectory: subdirectory) {
            return url
        }

        if let url = Bundle.main.url(forResource: fileName, withExtension: ext) {
            return url
        }

        let key = "\(fileName).\(ext)".lowercased()
        return resourceIndex[key]
    }

    private static func buildIndex() -> [String: URL] {
        guard let resourcePath = Bundle.main.resourcePath else { return [:] }
        let resourceURL = URL(fileURLWithPath: resourcePath)

        var index: [String: URL] = [:]
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return index
        }

        for case let fileURL as URL in enumerator {
            guard let isFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isFile else { continue }
            index[fileURL.lastPathComponent.lowercased()] = fileURL
        }

        return index
    }
}

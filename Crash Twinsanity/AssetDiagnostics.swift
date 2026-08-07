//
//  AssetDiagnostics.swift
//  Crash Bandicoot Game
//
//  Created on 08/07/2026.
//

import Foundation

/// Utility to verify asset files are properly bundled
class AssetDiagnostics {
    
    /// Check if all required Crash Bandicoot assets are in the bundle
    static func verifyAssets() {
        print("\n========== ASSET DIAGNOSTICS ==========")
        
        let assetFolder = "CrashBandicoot"

        // Check .obj file
        checkAsset(name: "CrashBandicoot", extension: "obj", folder: assetFolder)

        // Check .mtl file
        checkAsset(name: "CrashBandicoot", extension: "mtl", folder: assetFolder)

        // Check texture files (the .mtl references the PS2 texture variants)
        checkAsset(name: "CrashBody_PS2", extension: "png", folder: assetFolder)
        checkAsset(name: "CrashEye_PS2", extension: "png", folder: assetFolder)
        checkAsset(name: "CrashEyelid_PS2", extension: "png", folder: assetFolder)

        print("========================================\n")
    }

    private static func checkAsset(name: String, extension ext: String, folder: String) {
        if let url = BundleAssetLocator.find(fileName: name, extension: ext, preferredSubdirectory: folder) {
            print("✅ FOUND: \(name).\(ext)")
            print("   Path: \(url.path)")

            // Check if file actually exists and get size
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let fileSize = attributes[.size] as? Int64 {
                let sizeInKB = Double(fileSize) / 1024.0
                print("   Size: \(String(format: "%.2f", sizeInKB)) KB")
            }
        } else {
            print("❌ MISSING: \(name).\(ext)")
            print("   Expected in folder: \(folder)")
        }
        print("")
    }
    
    /// List all resources in the bundle (useful for debugging)
    static func listAllBundleResources() {
        print("\n========== ALL BUNDLE RESOURCES ==========")
        
        if let resourcePath = Bundle.main.resourcePath {
            print("Bundle resource path: \(resourcePath)")
            
            do {
                let items = try FileManager.default.contentsOfDirectory(atPath: resourcePath)
                print("\nFiles in bundle root:")
                for item in items.sorted() {
                    print("  - \(item)")
                }
                
                // Check for CrashBandicoot folder
                let crashFolder = (resourcePath as NSString).appendingPathComponent("CrashBandicoot")
                if FileManager.default.fileExists(atPath: crashFolder) {
                    print("\n✅ CrashBandicoot folder found!")
                    let crashItems = try FileManager.default.contentsOfDirectory(atPath: crashFolder)
                    print("Files inside CrashBandicoot folder:")
                    for item in crashItems.sorted() {
                        print("  - \(item)")
                    }
                } else {
                    print("\n❌ CrashBandicoot folder NOT found in bundle")
                }
                
            } catch {
                print("Error reading bundle: \(error)")
            }
        }
        
        print("==========================================\n")
    }
}

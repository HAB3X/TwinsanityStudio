//
//  PlayerCharacter.swift
//  Crash Bandicoot Game
//
//  Created on 08/07/2026.
//

import SceneKit

/// Represents the player-controlled character with physics, animation, and state management
class PlayerCharacter {
    
    // MARK: - Properties
    
    let node: SCNNode
    private var modelNode: SCNNode?
    
    // Movement properties
    var moveSpeed: CGFloat = 5.0
    var rotationSpeed: CGFloat = 3.0
    private var currentVelocity = SCNVector3.zero
    
    // Physics properties
    private let characterHeight: CGFloat = 2.0
    private let characterRadius: CGFloat = 0.5
    
    // MARK: - Initialization
    
    init() {
        self.node = SCNNode()
        self.node.name = "player"
        
        setupPhysics()
    }
    
    // MARK: - Model Loading
    
    /// Loads the character model from the project assets
    /// - Parameter assetFolder: The name of the folder containing the .obj and texture files
    func loadModel(fromFolder assetFolder: String) {
        guard let modelScene = loadOBJModel(folderName: assetFolder, fileName: "CrashBandicoot") else {
            print("⚠️ Failed to load character model. Using placeholder.")
            createPlaceholderModel()
            return
        }
        
        // Extract the model node
        if let loadedModel = modelScene.rootNode.childNodes.first {
            modelNode = loadedModel
            
            // Configure model appearance
            configureModelMaterials()
            
            // The raw model is ~1.95 units tall, which already matches
            // characterHeight, so no extra scaling is needed.
            modelNode?.scale = SCNVector3(1.0, 1.0, 1.0)
            
            // Center the model on the character node
            centerModel()
            
            node.addChildNode(loadedModel)
        } else {
            print("⚠️ Model loaded but no child nodes found. Using placeholder.")
            createPlaceholderModel()
        }
    }
    
    private func loadOBJModel(folderName: String, fileName: String) -> SCNScene? {
        guard let modelURL = BundleAssetLocator.find(fileName: fileName, extension: "obj", preferredSubdirectory: folderName) else {
            print("❌ Could not find \(fileName).obj anywhere in the bundle")
            return nil
        }

        do {
            let scene = try SCNScene(url: modelURL, options: [
                .checkConsistency: true,
                .flattenScene: false,
                .createNormalsIfAbsent: true
            ])
            print("✅ Successfully loaded \(fileName).obj from \(modelURL.path)")
            return scene
        } catch {
            print("❌ Error loading OBJ file: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func configureModelMaterials() {
        guard let model = modelNode else { return }
        
        // Recursively configure all child nodes
        model.enumerateChildNodes { (node, _) in
            guard let geometry = node.geometry else { return }
            
            // Configure each material
            for material in geometry.materials {
                material.lightingModel = .physicallyBased
                material.isDoubleSided = false
                
                // If textures weren't loaded automatically, try to load them manually
                if material.diffuse.contents == nil {
                    self.tryLoadTextures(for: material, node: node)
                }
            }
        }
    }
    
    private func tryLoadTextures(for material: SCNMaterial, node: SCNNode) {
        // The .mtl file should reference the textures, but we can fallback.
        // Match the material name to the right texture so we don't paint
        // the whole model with a single texture by accident.
        let materialName = (material.name ?? "").lowercased()
        let nodeName = (node.name ?? "").lowercased()
        let haystack = materialName + " " + nodeName

        let candidates: [String]
        if haystack.contains("eyelid") {
            candidates = ["CrashEyelid_PS2", "CrashEyelid"]
        } else if haystack.contains("eye") {
            candidates = ["CrashEye_PS2", "CrashEye"]
        } else {
            candidates = ["CrashBody_PS2", "CrashBody", "CrashEye_PS2", "CrashEyelid_PS2"]
        }

        for textureName in candidates {
            if let textureURL = BundleAssetLocator.find(fileName: textureName, extension: "png", preferredSubdirectory: "CrashBandicoot"),
               let image = NSImage(contentsOf: textureURL) {
                material.diffuse.contents = image
                print("✅ Loaded texture: \(textureName).png")
                return
            }
        }
    }
    
    private func centerModel() {
        guard let model = modelNode else { return }
        
        // Calculate bounding box
        let (min, max) = model.boundingBox
        let centerOffset = SCNVector3(
            -(min.x + max.x) / 2,
            -min.y, // Keep feet on the ground
            -(min.z + max.z) / 2
        )
        
        model.position = centerOffset
    }
    
    private func createPlaceholderModel() {
        // Create a simple capsule as a placeholder
        let capsuleGeometry = SCNCapsule(capRadius: characterRadius, height: characterHeight)
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemOrange
        capsuleGeometry.materials = [material]
        
        let capsuleNode = SCNNode(geometry: capsuleGeometry)
        capsuleNode.position = SCNVector3(0, characterHeight / 2, 0)
        
        node.addChildNode(capsuleNode)
        modelNode = capsuleNode
    }
    
    // MARK: - Physics Setup
    
    private func setupPhysics() {
        // Create capsule physics shape for character collision
        let physicsShape = SCNPhysicsShape(
            geometry: SCNCapsule(capRadius: characterRadius, height: characterHeight),
            options: nil
        )
        
        let physicsBody = SCNPhysicsBody(type: .dynamic, shape: physicsShape)
        physicsBody.mass = 1.0
        physicsBody.friction = 0.8
        physicsBody.restitution = 0.0
        physicsBody.damping = 0.5
        physicsBody.angularDamping = 1.0 // Prevent character from tipping over
        
        // Lock rotation on X and Z axes so character stays upright
        physicsBody.angularVelocityFactor = SCNVector3(0, 1, 0)
        
        node.physicsBody = physicsBody
        
        // Start slightly above ground
        node.position = SCNVector3(0, 2, 0)
    }
    
    // MARK: - Movement Methods
    
    /// Apply movement in a given direction
    /// - Parameter direction: Normalized direction vector in world space
    func move(direction: SCNVector3) {
        guard let physicsBody = node.physicsBody else { return }
        
        // Calculate movement velocity
        let movement = SCNVector3(
            direction.x * moveSpeed,
            physicsBody.velocity.y, // Preserve gravity/jumping
            direction.z * moveSpeed
        )
        
        physicsBody.velocity = movement
        currentVelocity = movement
        
        // Rotate character to face movement direction
        if direction.x != 0 || direction.z != 0 {
            let angle = atan2(direction.x, direction.z)
            let targetRotation = SCNVector4(0, 1, 0, angle)
            
            // Smooth rotation using SCNAction
            let rotateAction = SCNAction.rotateTo(
                x: 0,
                y: CGFloat(angle),
                z: 0,
                duration: 0.1
            )
            rotateAction.timingMode = .easeOut
            
            node.runAction(rotateAction)
        }
    }
    
    /// Stop all horizontal movement
    func stopMovement() {
        guard let physicsBody = node.physicsBody else { return }
        
        // Keep vertical velocity (gravity), zero out horizontal
        physicsBody.velocity = SCNVector3(0, physicsBody.velocity.y, 0)
        currentVelocity = SCNVector3.zero
    }
    
    // MARK: - Update Loop
    
    /// Called each frame to update character state
    /// - Parameter deltaTime: Time since last frame
    func update(deltaTime: TimeInterval) {
        // Future: Add animation state updates, particle effects, etc.
    }
}

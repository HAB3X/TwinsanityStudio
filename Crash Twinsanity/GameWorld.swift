//
//  GameWorld.swift
//  Crash Bandicoot Game
//
//  Created on 08/07/2026.
//

import SceneKit

/// Manages the 3D game environment including floor, walls, lighting, and physics
class GameWorld {
    
    // MARK: - Properties
    
    let scene: SCNScene
    private let worldSize: CGFloat
    private let wallHeight: CGFloat
    
    // MARK: - Initialization
    
    init(worldSize: CGFloat = 50.0, wallHeight: CGFloat = 10.0) {
        self.scene = SCNScene()
        self.worldSize = worldSize
        self.wallHeight = wallHeight
        
        setupEnvironment()
        setupLighting()
        setupPhysics()
    }
    
    // MARK: - Environment Setup
    
    private func setupEnvironment() {
        createFloor()
        createBoundaryWalls()
        createSkybox()
    }
    
    private func createFloor() {
        let floorGeometry = SCNFloor()
        floorGeometry.reflectivity = 0.1
        
        // Create a material for the floor
        let floorMaterial = SCNMaterial()
        floorMaterial.diffuse.contents = NSColor.systemGreen
        floorMaterial.lightingModel = .physicallyBased
        floorGeometry.materials = [floorMaterial]
        
        let floorNode = SCNNode(geometry: floorGeometry)
        floorNode.name = "floor"
        
        // Add physics body for collision
        let floorPhysicsBody = SCNPhysicsBody(type: .static, shape: nil)
        floorPhysicsBody.restitution = 0.0
        floorPhysicsBody.friction = 0.8
        floorNode.physicsBody = floorPhysicsBody
        
        scene.rootNode.addChildNode(floorNode)
    }
    
    private func createBoundaryWalls() {
        let wallThickness: CGFloat = 1.0
        
        // North wall
        createWall(
            position: SCNVector3(0, wallHeight / 2, -worldSize / 2),
            size: SCNVector3(worldSize, wallHeight, wallThickness)
        )
        
        // South wall
        createWall(
            position: SCNVector3(0, wallHeight / 2, worldSize / 2),
            size: SCNVector3(worldSize, wallHeight, wallThickness)
        )
        
        // East wall
        createWall(
            position: SCNVector3(worldSize / 2, wallHeight / 2, 0),
            size: SCNVector3(wallThickness, wallHeight, worldSize)
        )
        
        // West wall
        createWall(
            position: SCNVector3(-worldSize / 2, wallHeight / 2, 0),
            size: SCNVector3(wallThickness, wallHeight, worldSize)
        )
    }
    
    private func createWall(position: SCNVector3, size: SCNVector3) {
        let wallGeometry = SCNBox(
            width: size.x,
            height: size.y,
            length: size.z,
            chamferRadius: 0
        )
        
        let wallMaterial = SCNMaterial()
        wallMaterial.diffuse.contents = NSColor.systemGray
        wallMaterial.lightingModel = .physicallyBased
        wallGeometry.materials = [wallMaterial]
        
        let wallNode = SCNNode(geometry: wallGeometry)
        wallNode.position = position
        wallNode.name = "wall"
        
        // Add static physics body
        let wallPhysicsBody = SCNPhysicsBody(type: .static, shape: nil)
        wallPhysicsBody.restitution = 0.0
        wallNode.physicsBody = wallPhysicsBody
        
        scene.rootNode.addChildNode(wallNode)
    }
    
    private func createSkybox() {
        // Simple gradient background
        scene.background.contents = [
            NSColor(calibratedRed: 0.4, green: 0.6, blue: 0.9, alpha: 1.0), // Sky blue
            NSColor(calibratedRed: 0.6, green: 0.7, blue: 0.9, alpha: 1.0),
            NSColor(calibratedRed: 0.5, green: 0.7, blue: 0.95, alpha: 1.0),
            NSColor(calibratedRed: 0.4, green: 0.6, blue: 0.9, alpha: 1.0),
            NSColor(calibratedRed: 0.3, green: 0.5, blue: 0.8, alpha: 1.0),
            NSColor(calibratedRed: 0.5, green: 0.65, blue: 0.85, alpha: 1.0)
        ]
    }
    
    // MARK: - Lighting Setup
    
    private func setupLighting() {
        // Ambient light
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.color = NSColor(white: 0.3, alpha: 1.0)
        ambientLight.light?.intensity = 300
        scene.rootNode.addChildNode(ambientLight)
        
        // Main directional light (sun)
        let sunLight = SCNNode()
        sunLight.light = SCNLight()
        sunLight.light?.type = .directional
        sunLight.light?.color = NSColor.white
        sunLight.light?.intensity = 1000
        sunLight.light?.castsShadow = true
        sunLight.light?.shadowMode = .deferred
        sunLight.light?.shadowSampleCount = 16
        sunLight.position = SCNVector3(10, 20, 10)
        sunLight.eulerAngles = SCNVector3(-CGFloat.pi / 4, CGFloat.pi / 4, 0)
        scene.rootNode.addChildNode(sunLight)
        
        // Fill light
        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .omni
        fillLight.light?.color = NSColor(white: 0.5, alpha: 1.0)
        fillLight.light?.intensity = 500
        fillLight.position = SCNVector3(-10, 10, 10)
        scene.rootNode.addChildNode(fillLight)
    }
    
    // MARK: - Physics Setup
    
    private func setupPhysics() {
        scene.physicsWorld.gravity = SCNVector3(0, -9.8, 0)
    }
    
    // MARK: - Public Methods
    
    func addNode(_ node: SCNNode) {
        scene.rootNode.addChildNode(node)
    }
    
    func removeNode(_ node: SCNNode) {
        node.removeFromParentNode()
    }
}

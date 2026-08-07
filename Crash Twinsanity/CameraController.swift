//
//  CameraController.swift
//  Crash Bandicoot Game
//
//  Created on 08/07/2026.
//

import SceneKit

/// Manages the game camera following the player character
class CameraController {
    
    // MARK: - Properties
    
    let cameraNode: SCNNode
    private weak var target: SCNNode?
    
    // Camera settings
    var distance: CGFloat = 10.0
    var height: CGFloat = 5.0
    var angle: CGFloat = -CGFloat.pi / 6 // Look down slightly
    var followSpeed: CGFloat = 3.0
    
    // MARK: - Initialization
    
    init(target: SCNNode) {
        self.cameraNode = SCNNode()
        self.target = target
        
        setupCamera()
        updatePosition(immediate: true)
    }
    
    // MARK: - Setup
    
    private func setupCamera() {
        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = 1000.0
        camera.fieldOfView = 60.0
        
        cameraNode.camera = camera
        cameraNode.name = "camera"
    }
    
    // MARK: - Update
    
    /// Update camera position to follow target
    /// - Parameters:
    ///   - deltaTime: Time since last frame
    ///   - immediate: If true, snap to position instantly
    func updatePosition(deltaTime: TimeInterval = 0, immediate: Bool = false) {
        guard let target = target else { return }
        
        // Calculate desired camera position
        let targetPosition = target.position
        let cameraOffset = SCNVector3(
            0,
            height,
            distance
        )
        
        let desiredPosition = SCNVector3(
            targetPosition.x + cameraOffset.x,
            targetPosition.y + cameraOffset.y,
            targetPosition.z + cameraOffset.z
        )
        
        if immediate {
            cameraNode.position = desiredPosition
        } else {
            // Smooth follow
            let t = CGFloat(deltaTime) * followSpeed
            cameraNode.position = cameraNode.position.lerp(to: desiredPosition, t: t)
        }
        
        // Always look at target
        cameraNode.look(at: SCNVector3(
            targetPosition.x,
            targetPosition.y + CGFloat(1.0), // Look at character's center
            targetPosition.z
        ))
    }
    
    // MARK: - Helper Methods
    
    // Removed - now using SCNVector3.lerp() extension
}

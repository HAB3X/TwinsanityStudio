//
//  InputManager.swift
//  Crash Bandicoot Game
//
//  Created on 08/07/2026.
//

import AppKit
import SceneKit

/// Handles all keyboard input for player controls
class InputManager {
    
    // MARK: - Properties
    
    private var keysPressed: Set<UInt16> = []
    
    // Key codes for WASD
    private enum KeyCode: UInt16 {
        case w = 13
        case a = 0
        case s = 1
        case d = 2
        case space = 49
        case escape = 53
    }
    
    // MARK: - Input Handling
    
    func handleKeyDown(with event: NSEvent) {
        keysPressed.insert(event.keyCode)
    }
    
    func handleKeyUp(with event: NSEvent) {
        keysPressed.remove(event.keyCode)
    }
    
    // MARK: - Movement Input
    
    /// Returns the current movement direction based on pressed keys
    /// - Parameter cameraNode: The camera node to calculate relative movement
    /// - Returns: Normalized direction vector in world space
    func getMovementDirection(relativeTo cameraNode: SCNNode) -> SCNVector3 {
        var direction = SCNVector3.zero
        
        // Get camera's forward and right vectors (projected onto XZ plane)
        let cameraTransform = cameraNode.transform
        let cameraForward = SCNVector3(cameraTransform.m31, 0, cameraTransform.m33).normalized
        let cameraRight = SCNVector3(cameraTransform.m11, 0, cameraTransform.m13).normalized

        // Calculate direction based on input
        if keysPressed.contains(KeyCode.w.rawValue) {
            direction = direction + cameraForward
        }
        if keysPressed.contains(KeyCode.s.rawValue) {
            direction = direction - cameraForward
        }
        if keysPressed.contains(KeyCode.a.rawValue) {
            direction = direction - cameraRight
        }
        if keysPressed.contains(KeyCode.d.rawValue) {
            direction = direction + cameraRight
        }

        // Normalize the final direction
        if direction.length > 0 {
            direction = direction.normalized
        }

        return direction
    }
    
    /// Check if any movement key is pressed
    func isMoving() -> Bool {
        return keysPressed.contains(KeyCode.w.rawValue) ||
               keysPressed.contains(KeyCode.s.rawValue) ||
               keysPressed.contains(KeyCode.a.rawValue) ||
               keysPressed.contains(KeyCode.d.rawValue)
    }
    
    /// Check if space bar is pressed (for jumping)
    func isJumpPressed() -> Bool {
        return keysPressed.contains(KeyCode.space.rawValue)
    }
    
    /// Check if escape is pressed
    func isEscapePressed() -> Bool {
        return keysPressed.contains(KeyCode.escape.rawValue)
    }
}

//
//  SCNVector3+Extensions.swift
//  Crash Bandicoot Game
//
//  Created on 08/07/2026.
//

import SceneKit

// MARK: - SCNVector3 Extensions

extension SCNVector3 {
    
    /// Zero vector constant
    static let zero = SCNVector3(0, 0, 0)
    
    // MARK: - Vector Math Operations
    
    /// Add two vectors
    static func + (left: SCNVector3, right: SCNVector3) -> SCNVector3 {
        return SCNVector3(left.x + right.x, left.y + right.y, left.z + right.z)
    }
    
    /// Subtract two vectors
    static func - (left: SCNVector3, right: SCNVector3) -> SCNVector3 {
        return SCNVector3(left.x - right.x, left.y - right.y, left.z - right.z)
    }
    
    /// Multiply vector by scalar (CGFloat)
    static func * (vector: SCNVector3, scalar: CGFloat) -> SCNVector3 {
        return SCNVector3(vector.x * scalar, vector.y * scalar, vector.z * scalar)
    }
    
    /// Multiply vector by scalar (Float)
    static func * (vector: SCNVector3, scalar: Float) -> SCNVector3 {
        return vector * CGFloat(scalar)
    }
    
    /// Divide vector by scalar (CGFloat)
    static func / (vector: SCNVector3, scalar: CGFloat) -> SCNVector3 {
        return SCNVector3(vector.x / scalar, vector.y / scalar, vector.z / scalar)
    }
    
    /// Divide vector by scalar (Float)
    static func / (vector: SCNVector3, scalar: Float) -> SCNVector3 {
        return vector / CGFloat(scalar)
    }
    
    // MARK: - Vector Properties
    
    /// Calculate the length (magnitude) of the vector
    var length: CGFloat {
        return sqrt(x * x + y * y + z * z)
    }
    
    /// Calculate the squared length (faster than length when comparing distances)
    var lengthSquared: CGFloat {
        return x * x + y * y + z * z
    }
    
    /// Returns a normalized version of this vector
    var normalized: SCNVector3 {
        let len = length
        return len > 0 ? self / len : .zero
    }
    
    // MARK: - Vector Operations
    
    /// Calculate distance between two points
    func distance(to other: SCNVector3) -> CGFloat {
        return (self - other).length
    }
    
    /// Calculate dot product with another vector
    func dot(_ other: SCNVector3) -> CGFloat {
        return x * other.x + y * other.y + z * other.z
    }
    
    /// Calculate cross product with another vector
    func cross(_ other: SCNVector3) -> SCNVector3 {
        return SCNVector3(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }
    
    /// Linear interpolation between this vector and another
    func lerp(to other: SCNVector3, t: CGFloat) -> SCNVector3 {
        let clampedT = min(max(t, 0), 1)
        let diff = other - self
        let scaled = diff * clampedT
        return self + scaled
    }
    
    /// Linear interpolation between this vector and another (Float version)
    func lerp(to other: SCNVector3, t: Float) -> SCNVector3 {
        return lerp(to: other, t: CGFloat(t))
    }
}

// MARK: - Convenience Initializers

extension SCNVector3 {
    
    /// Create vector with same value for all components (Float)
    init(uniform value: Float) {
        self.init(CGFloat(value), CGFloat(value), CGFloat(value))
    }
    
    /// Create vector with same value for all components (CGFloat)
    init(uniform value: CGFloat) {
        self.init(value, value, value)
    }
}

// MARK: - Debug Helpers

extension SCNVector3: CustomStringConvertible {
    
    public var description: String {
        return String(format: "(%.2f, %.2f, %.2f)", Float(x), Float(y), Float(z))
    }
}

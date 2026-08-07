//
//  GameViewController.swift
//  Crash Twinsanity
//
//  Created on 08/07/2026.
//

import SceneKit
import AppKit

/// Main game view controller. Builds the 3D world, loads Crash Bandicoot,
/// points a third-person camera at him, and drives WASD movement each frame.
class GameViewController: NSViewController {

    // MARK: - Properties

    private var sceneView: SCNView!

    // Game systems
    private var gameWorld: GameWorld!
    private var player: PlayerCharacter!
    private var inputManager: InputManager!
    private var cameraController: CameraController!

    // Update loop
    private var lastUpdateTime: TimeInterval = 0

    // MARK: - Lifecycle

    override func loadView() {
        sceneView = SCNView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
        self.view = sceneView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupGame()
        configureSceneView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        // The SCNView must be first responder or WASD key events never reach it.
        view.window?.makeFirstResponder(self)
    }

    // MARK: - Game Setup

    private func setupGame() {
        print("\n🔍 Checking for Crash Bandicoot assets...")
        AssetDiagnostics.verifyAssets()

        // Build the physical world: floor, boundary walls, lighting, gravity.
        gameWorld = GameWorld(worldSize: 50, wallHeight: 10)

        // Load Crash Bandicoot from CrashBandicoot.obj/.mtl + textures and
        // place him standing on the floor.
        player = PlayerCharacter()
        player.loadModel(fromFolder: "CrashBandicoot")
        gameWorld.addNode(player.node)

        // Third-person camera that follows and looks at Crash.
        cameraController = CameraController(target: player.node)
        gameWorld.addNode(cameraController.cameraNode)

        inputManager = InputManager()

        sceneView.scene = gameWorld.scene
        sceneView.pointOfView = cameraController.cameraNode
    }

    private func configureSceneView() {
        sceneView.backgroundColor = NSColor.black
        sceneView.allowsCameraControl = false // We drive the camera ourselves
        sceneView.showsStatistics = true
        sceneView.autoenablesDefaultLighting = false // GameWorld sets up its own lights
        sceneView.antialiasingMode = .multisampling4X

        sceneView.delegate = self
        sceneView.isPlaying = true
    }

    // MARK: - Input Handling

    override func keyDown(with event: NSEvent) {
        inputManager.handleKeyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        inputManager.handleKeyUp(with: event)
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    // MARK: - Game Update

    private func update(deltaTime: TimeInterval) {
        let movementDirection = inputManager.getMovementDirection(relativeTo: cameraController.cameraNode)

        if inputManager.isMoving() {
            player.move(direction: movementDirection)
        } else {
            player.stopMovement()
        }

        player.update(deltaTime: deltaTime)
        cameraController.updatePosition(deltaTime: deltaTime)
    }
}

// MARK: - SCNSceneRendererDelegate

extension GameViewController: SCNSceneRendererDelegate {

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let deltaTime = lastUpdateTime == 0 ? 0 : time - lastUpdateTime
        lastUpdateTime = time

        update(deltaTime: deltaTime)
    }
}

# 🏗️ Architecture Diagram

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      GameViewController                         │
│                   (Main Game Orchestrator)                      │
│                                                                 │
│  • Owns all game systems                                       │
│  • Manages game loop (60 FPS)                                  │
│  • Routes input events                                         │
│  • Updates all systems each frame                              │
└────────┬──────────────┬─────────────┬───────────────┬──────────┘
         │              │             │               │
         │              │             │               │
         ▼              ▼             ▼               ▼
    ┌─────────┐   ┌──────────┐  ┌─────────┐   ┌──────────────┐
    │  Game   │   │  Player  │  │  Input  │   │   Camera     │
    │  World  │   │Character │  │ Manager │   │  Controller  │
    └─────────┘   └──────────┘  └─────────┘   └──────────────┘
```

---

## Detailed Component Breakdown

### 1️⃣ GameViewController (Brain of the Game)

```
GameViewController
│
├── Properties
│   ├── sceneView: SCNView
│   ├── gameWorld: GameWorld
│   ├── player: PlayerCharacter
│   ├── inputManager: InputManager
│   └── cameraController: CameraController
│
├── Lifecycle
│   ├── loadView() → Create SCNView
│   ├── viewDidLoad() → Setup game systems
│   └── setupGame() → Initialize all components
│
├── Input Handling
│   ├── keyDown() → Pass to InputManager
│   └── keyUp() → Pass to InputManager
│
└── Game Loop
    └── renderer(_:updateAtTime:)
        ├── Calculate deltaTime
        ├── Get input from InputManager
        ├── Update player movement
        ├── Update camera position
        └── (60 times per second)
```

**Responsibilities:**
- Creates and initializes all game systems
- Runs the main game loop
- Routes input to InputManager
- Updates all systems based on input
- Manages the SCNView

---

### 2️⃣ GameWorld (Environment Manager)

```
GameWorld
│
├── Properties
│   ├── scene: SCNScene
│   ├── worldSize: CGFloat
│   └── wallHeight: CGFloat
│
├── Environment
│   ├── createFloor()
│   │   ├── Green material
│   │   ├── Physics body (static)
│   │   └── Collision enabled
│   │
│   ├── createBoundaryWalls()
│   │   ├── North wall
│   │   ├── South wall
│   │   ├── East wall
│   │   └── West wall
│   │
│   └── createSkybox()
│       └── Gradient background
│
├── Lighting
│   ├── Ambient light (overall illumination)
│   ├── Directional light (sun, with shadows)
│   └── Fill light (reduce harsh shadows)
│
└── Physics
    └── Gravity (9.8 m/s²)
```

**Responsibilities:**
- Creates the 3D environment
- Manages floor and walls with collision
- Sets up professional lighting
- Configures physics world (gravity)
- Provides methods to add/remove nodes

---

### 3️⃣ PlayerCharacter (Player Entity)

```
PlayerCharacter
│
├── Properties
│   ├── node: SCNNode (root node)
│   ├── modelNode: SCNNode? (3D model)
│   ├── moveSpeed: Float
│   ├── rotationSpeed: Float
│   └── currentVelocity: SCNVector3
│
├── Initialization
│   ├── Create root node
│   └── Setup physics body (capsule)
│
├── Model Loading
│   ├── loadModel(fromFolder:)
│   │   ├── Load .obj file
│   │   ├── Load .mtl materials
│   │   ├── Load .png textures
│   │   ├── Configure materials (PBR)
│   │   ├── Scale model
│   │   └── Center model
│   │
│   └── createPlaceholderModel()
│       └── Fallback orange capsule
│
├── Physics
│   ├── Dynamic physics body
│   ├── Mass, friction, damping
│   ├── Lock X/Z rotation (stay upright)
│   └── Collision detection
│
├── Movement
│   ├── move(direction:)
│   │   ├── Apply velocity
│   │   ├── Rotate to face direction
│   │   └── Smooth rotation animation
│   │
│   └── stopMovement()
│       └── Zero horizontal velocity
│
└── Update
    └── update(deltaTime:)
        └── Frame-by-frame logic
```

**Responsibilities:**
- Loads and manages the 3D character model
- Handles character physics and collision
- Applies movement based on input
- Rotates character to face movement direction
- Stays upright (no tipping over)

---

### 4️⃣ InputManager (Input Handler)

```
InputManager
│
├── Properties
│   ├── keysPressed: Set<UInt16>
│   └── KeyCode enum (W/A/S/D/Space/Esc)
│
├── Input Handling
│   ├── handleKeyDown(event:)
│   │   └── Add key to set
│   │
│   └── handleKeyUp(event:)
│       └── Remove key from set
│
├── Movement Queries
│   ├── getMovementDirection(relativeTo:)
│   │   ├── Get camera forward/right vectors
│   │   ├── Project onto XZ plane
│   │   ├── Combine based on WASD
│   │   └── Return normalized direction
│   │
│   ├── isMoving() → Bool
│   ├── isJumpPressed() → Bool
│   └── isEscapePressed() → Bool
│
└── Vector Math
    ├── add()
    ├── subtract()
    ├── length()
    └── normalize()
```

**Responsibilities:**
- Tracks which keys are currently pressed
- Translates WASD to movement direction
- Calculates camera-relative movement
- Provides query methods for game state

---

### 5️⃣ CameraController (Camera Manager)

```
CameraController
│
├── Properties
│   ├── cameraNode: SCNNode
│   ├── target: SCNNode (player)
│   ├── distance: Float
│   ├── height: Float
│   ├── angle: Float
│   └── followSpeed: Float
│
├── Setup
│   ├── Create SCNCamera
│   ├── Configure FOV, near/far planes
│   └── Initial position
│
└── Update
    └── updatePosition(deltaTime:)
        ├── Calculate desired position
        │   ├── Behind player
        │   ├── Above player
        │   └── At configured distance
        │
        ├── Smooth interpolation (lerp)
        │   └── Move toward desired position
        │
        └── Look at player center
```

**Responsibilities:**
- Manages the game camera
- Follows the player smoothly
- Always looks at player character
- Configurable distance and height
- Smooth camera movement (no snapping)

---

### 6️⃣ SCNVector3+Extensions (Utility)

```
SCNVector3+Extensions
│
├── Operators
│   ├── + (addition)
│   ├── - (subtraction)
│   ├── * (scalar multiply)
│   └── / (scalar divide)
│
├── Properties
│   ├── length → Float
│   ├── lengthSquared → Float
│   └── normalized → SCNVector3
│
├── Methods
│   ├── distance(to:) → Float
│   ├── dot() → Float
│   ├── cross() → SCNVector3
│   └── lerp(to:t:) → SCNVector3
│
└── Convenience
    ├── init(uniform:)
    └── CustomStringConvertible
```

**Responsibilities:**
- Makes vector math readable
- Provides common operations
- Reduces code duplication

---

## 🔄 Data Flow

### Startup Flow
```
1. GameViewController.viewDidLoad()
   ↓
2. Create GameWorld
   ↓
3. Create PlayerCharacter
   ↓
4. Load 3D model from assets
   ↓
5. Create InputManager
   ↓
6. Create CameraController
   ↓
7. Add player to world
   ↓
8. Add camera to world
   ↓
9. Start render loop
```

### Frame Update Flow (60 FPS)
```
1. renderer(_:updateAtTime:) called
   ↓
2. Calculate deltaTime
   ↓
3. InputManager.getMovementDirection()
   ├── Check WASD keys
   ├── Get camera forward/right
   └── Return direction vector
   ↓
4. PlayerCharacter.move(direction:)
   ├── Apply physics velocity
   ├── Rotate to face direction
   └── Smooth rotation
   ↓
5. PlayerCharacter.update(deltaTime:)
   └── Future: animations, effects
   ↓
6. CameraController.updatePosition()
   ├── Calculate desired position
   ├── Lerp to smooth follow
   └── Look at player
   ↓
7. SceneKit renders frame
   └── Display on screen
```

### Input Flow
```
User presses key
   ↓
NSEvent generated by macOS
   ↓
GameViewController.keyDown(with:)
   ↓
InputManager.handleKeyDown(with:)
   ↓
Key added to keysPressed set
   ↓
(Next frame update)
   ↓
InputManager.getMovementDirection()
   ↓
Direction calculated based on active keys
   ↓
PlayerCharacter.move(direction:)
   ↓
Character moves!
```

---

## 🎯 Design Principles Applied

### Single Responsibility Principle
Each class has ONE job:
- GameWorld → Environment
- PlayerCharacter → Player entity
- InputManager → Input only
- CameraController → Camera only
- GameViewController → Orchestration

### Encapsulation
Private implementation details:
- Internal methods marked `private`
- Physics bodies not exposed
- Model loading details hidden

### Dependency Injection
Components receive dependencies:
```swift
CameraController(target: player.node)
```
Not:
```swift
CameraController() // finds player itself ❌
```

### Open/Closed Principle
Easy to extend without modifying:
- Add new input keys → Edit InputManager only
- Add new environment objects → Edit GameWorld only
- Add animations → Edit PlayerCharacter only

---

## 📦 Asset Loading Flow

```
PlayerCharacter.loadModel(fromFolder: "CrashBandicoot")
   ↓
Bundle.main.url(forResource:withExtension:subdirectory:)
   ↓
Find "CrashBandicoot.obj" in app bundle
   ↓
SCNScene(url:options:)
   ↓
SceneKit parses .obj file
   ↓
SceneKit reads .mtl file (materials)
   ↓
SceneKit loads referenced .png textures
   ↓
Model created with materials applied
   ↓
configureModelMaterials()
   ├── Set PBR lighting
   ├── Verify textures loaded
   └── Apply to all materials
   ↓
Scale and center model
   ↓
Add to player.node
   ↓
Character appears in game!
```

---

## 🔍 Physics Interaction

```
SceneKit Physics World (gravity: 9.8 m/s²)
│
├── Floor (static body)
│   └── Collision category: default
│
├── Walls (static bodies)
│   └── Collision category: default
│
└── Player (dynamic body)
    ├── Mass: 1.0 kg
    ├── Friction: 0.8
    ├── Restitution: 0.0 (no bounce)
    ├── Damping: 0.5 (air resistance)
    ├── Angular damping: 1.0 (no spinning)
    └── Rotation locked (X/Z axes)

When player moves:
1. InputManager calculates direction
2. PlayerCharacter sets velocity on physics body
3. Physics engine applies forces
4. Collision detection (player vs floor/walls)
5. Physics resolves collisions
6. Node position updated
7. Rendered!
```

---

## 🎨 Rendering Pipeline

```
Each Frame (16.67ms @ 60 FPS)
│
├── Update Phase
│   ├── renderer(_:updateAtTime:) called
│   ├── Game logic runs
│   ├── Positions updated
│   └── Animations advanced
│
├── Simulation Phase
│   ├── Physics simulated
│   ├── Constraints solved
│   └── Collisions resolved
│
└── Render Phase
    ├── Frustum culling
    ├── Shadow map generation
    ├── Material shading (PBR)
    ├── Lighting calculations
    ├── Post-processing
    └── Present frame
```

---

## 💾 Memory Management

All classes use **Automatic Reference Counting (ARC)**:

```
GameViewController (strong)
   ├── owns → GameWorld (strong)
   ├── owns → PlayerCharacter (strong)
   ├── owns → InputManager (strong)
   └── owns → CameraController (strong)

CameraController
   └── weak → target: SCNNode (weak to avoid retain cycle)

All SCNNodes are managed by SceneKit's scene graph
```

No manual memory management needed! ✨

---

This architecture is **scalable**, **testable**, and **maintainable**. You can add features without breaking existing code! 🚀

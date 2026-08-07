# Crash Bandicoot 3D Game - Setup Guide

## Project Structure

Your Xcode project should be organized as follows:

```
YourProject/
├── GameViewController.swift
├── GameWorld.swift
├── PlayerCharacter.swift
├── InputManager.swift
├── CameraController.swift
└── CrashBandicoot/           ← Asset folder
    ├── CrashBandicoot.obj
    ├── CrashBandicoot.mtl
    ├── CrashBody.png
    ├── CrashEye.png
    └── CrashEyelid.png
```

## Adding Assets to Xcode

### Step 1: Create Asset Folder
1. In Xcode, right-click your project navigator
2. Select **New Group** and name it `CrashBandicoot`

### Step 2: Add Files
1. Drag all your model files (.obj, .mtl, .png) into the `CrashBandicoot` folder
2. **IMPORTANT**: When the dialog appears, make sure:
   - ✅ **"Copy items if needed"** is CHECKED
   - ✅ **"Create groups"** is selected (NOT "Create folder references")
   - ✅ Your app target is checked under "Add to targets"

### Step 3: Verify Files in Target
1. Select your project in the navigator
2. Select your app target
3. Go to **Build Phases** tab
4. Expand **Copy Bundle Resources**
5. Verify all asset files are listed:
   - CrashBandicoot.obj
   - CrashBandicoot.mtl
   - CrashBody.png
   - CrashEye.png
   - CrashEyelid.png

If they're missing, click the **+** button and add them.

## Fixing the "Unsigned Child" Error

### What This Error Means

The error **"dataset has an unsigned child"** in Xcode typically appears when:

1. **Asset files are not properly added to your target's bundle resources**
2. **Files exist in your project folder but aren't included in the build**
3. **Code signing issues with resource files** (less common)

This is NOT about code signing certificates for app distribution. It's about Xcode's internal asset management.

### Step-by-Step Fix

#### Solution 1: Re-add Assets to Target (Most Common Fix)

1. **Select each asset file** in the Project Navigator (CrashBandicoot.obj, etc.)
2. Open the **File Inspector** (right sidebar, or ⌥⌘1)
3. Look for **"Target Membership"** section
4. Ensure your app target is **CHECKED**

#### Solution 2: Clean and Rebuild

1. In Xcode menu: **Product → Clean Build Folder** (⇧⌘K)
2. Close Xcode completely
3. Navigate to your project folder in Finder
4. Delete these folders if they exist:
   - `DerivedData/`
   - `build/`
5. Reopen Xcode and build (⌘B)

#### Solution 3: Check Build Phases

1. Select your project in navigator
2. Select your target
3. Go to **Build Phases** tab
4. Expand **Copy Bundle Resources**
5. Remove any duplicate entries
6. If assets are missing, click **+** and add them
7. If assets show in red, remove them and re-add

#### Solution 4: Asset Catalog Check (If Using)

If you moved your assets to an Asset Catalog:
1. Select the Asset Catalog
2. Check **Target Membership** in File Inspector
3. Ensure it's included in your app target

#### Solution 5: File Permissions

Sometimes file permissions cause issues:
1. Open Terminal
2. Navigate to your project folder:
   ```bash
   cd /path/to/your/project
   ```
3. Fix permissions:
   ```bash
   chmod -R 755 CrashBandicoot/
   ```

### Verifying the Fix

After applying these solutions:
1. Build your project (⌘B)
2. Check for errors in the Issue Navigator
3. The "unsigned child" error should be gone

## OBJ Model Loading Tips

### Material File (.mtl) Setup

Make sure your `CrashBandicoot.mtl` file references textures correctly:

```mtl
newmtl CrashMaterial
Ka 1.000 1.000 1.000
Kd 1.000 1.000 1.000
Ks 0.000 0.000 0.000
Ns 10.000
map_Kd CrashBody.png    # Diffuse texture
map_Ks CrashEye.png     # Specular/detail texture
```

The texture filenames should match exactly (case-sensitive).

### Texture Format

- ✅ PNG format is recommended
- ✅ Power-of-2 dimensions work best (512x512, 1024x1024, etc.)
- ✅ sRGB color space for color textures

### Model Scale

If your character appears too large or small, adjust the scale in `PlayerCharacter.swift`:

```swift
// Line ~60
modelNode?.scale = SCNVector3(0.5, 0.5, 0.5)  // Adjust these values
```

## Running the Game

### macOS App Setup

If you haven't created the app yet:

1. Create new project: **File → New → Project**
2. Select **macOS → App**
3. Name it (e.g., "CrashBandicootGame")
4. Choose **AppKit** (not SwiftUI) for the interface
5. Replace the default ViewController with `GameViewController`

### Update AppDelegate

Make sure your `AppDelegate.swift` or `Main.storyboard` shows your GameViewController:

```swift
// If using programmatic setup:
func applicationDidFinishLaunching(_ aNotification: Notification) {
    if let window = NSApplication.shared.windows.first {
        let gameVC = GameViewController()
        window.contentViewController = gameVC
        window.makeKeyAndOrderFront(nil)
    }
}
```

### Window Configuration

For best experience, set window properties:
1. Select `Main.storyboard`
2. Select the Window
3. Set minimum size (800 x 600)
4. Enable resizing

## Controls

- **W** - Move forward
- **S** - Move backward
- **A** - Strafe left
- **D** - Strafe right
- **Space** - Jump (foundation implemented, needs physics)
- **Esc** - Quit/Pause (needs implementation)

## Build Settings to Check

### Deployment Target
- Ensure your **macOS Deployment Target** is set to a recent version (macOS 13.0+)

### Optimization
During development:
- **Debug configuration**: No optimization
- **Release configuration**: Optimize for speed

### Metal/OpenGL
SceneKit uses Metal by default on modern macOS:
- No special settings needed
- Metal provides better performance

## Troubleshooting Common Issues

### Character Not Visible
1. Check console for loading errors
2. Verify model files are in bundle
3. Try placeholder mode (automatically falls back)
4. Adjust camera distance in `CameraController.swift`

### Black Screen
1. Check if scene is assigned to sceneView
2. Verify camera is added to scene
3. Check lighting setup

### No Keyboard Input
1. Ensure `acceptsFirstResponder` returns `true`
2. Click on the game window to give it focus
3. Check Event Handling in Interface Builder

### Physics Not Working
1. Verify physics bodies are added
2. Check gravity is set
3. Ensure mass is not zero

### Poor Performance
1. Reduce shadow quality in `GameWorld.swift`
2. Lower `shadowSampleCount`
3. Disable `showsStatistics` in release builds
4. Optimize model polygon count

## Next Steps

### Adding Features

1. **Jump Mechanic**: Implement in `PlayerCharacter.swift`:
   ```swift
   func jump() {
       guard let physicsBody = node.physicsBody else { return }
       physicsBody.applyForce(SCNVector3(0, 50, 0), asImpulse: true)
   }
   ```

2. **Animation**: Add animation loading to `PlayerCharacter`:
   ```swift
   private func loadAnimations() {
       // Load .dae or .scn animation files
   }
   ```

3. **Level Design**: Extend `GameWorld` with platforms, obstacles

4. **Collectibles**: Create new class `Collectible`

5. **UI/HUD**: Add SwiftUI overlay for health, score

## Architecture Overview

The codebase follows strict OOP principles:

- **GameWorld**: Manages environment, physics world, lighting
- **PlayerCharacter**: Handles player model, movement, physics
- **InputManager**: Processes keyboard input independently
- **CameraController**: Manages camera following and positioning
- **GameViewController**: Orchestrates all systems, game loop

Each class is self-contained and communicates through well-defined interfaces.

## Resources

- [SceneKit Documentation](https://developer.apple.com/documentation/scenekit)
- [OBJ File Format Specification](http://paulbourke.net/dataformats/obj/)
- [SceneKit Best Practices](https://developer.apple.com/documentation/scenekit/scenekit_best_practices)

---

**Happy Game Development! 🎮**

# ⚡ Quick Start Checklist

Follow these steps in order to get your game running:

## ☐ Step 1: Create macOS App Project
- [ ] Open Xcode
- [ ] File → New → Project
- [ ] Select **macOS** → **App**
- [ ] Product Name: "CrashBandicootGame" (or your choice)
- [ ] Interface: **AppKit** (NOT SwiftUI)
- [ ] Language: Swift
- [ ] Click Create

## ☐ Step 2: Add Swift Files
- [ ] Drag `GameViewController.swift` into project
- [ ] Drag `GameWorld.swift` into project
- [ ] Drag `PlayerCharacter.swift` into project
- [ ] Drag `InputManager.swift` into project
- [ ] Drag `CameraController.swift` into project
- [ ] Drag `SCNVector3+Extensions.swift` into project

When the dialog appears for EACH file:
- [ ] ✅ Check "Copy items if needed"
- [ ] ✅ Ensure your app target is checked
- [ ] Click Finish

## ☐ Step 3: Add Asset Folder
- [ ] In Xcode Project Navigator, right-click your project
- [ ] Select **New Group**
- [ ] Name it `CrashBandicoot`
- [ ] Drag these files INTO the CrashBandicoot group:
  - [ ] CrashBandicoot.obj
  - [ ] CrashBandicoot.mtl
  - [ ] CrashBody.png
  - [ ] CrashEye.png
  - [ ] CrashEyelid.png

When the dialog appears:
- [ ] ✅ Check "Copy items if needed"
- [ ] ✅ Select "Create groups" (yellow folder icon)
- [ ] ✅ Ensure your app target is checked
- [ ] Click Finish

## ☐ Step 4: Verify Asset Target Membership

For EACH asset file (obj, mtl, all png files):
- [ ] Click the file in Project Navigator
- [ ] Open File Inspector (right panel, or ⌥⌘1)
- [ ] Find "Target Membership" section
- [ ] ✅ Ensure your app target is CHECKED

## ☐ Step 5: Configure Main View Controller

### Option A: Using Storyboard (Recommended for beginners)
- [ ] Open `Main.storyboard`
- [ ] Select the View Controller in the scene
- [ ] Open Identity Inspector (right panel, or ⌥⌘3)
- [ ] Under "Custom Class", set Class to: `GameViewController`

### Option B: Programmatic Setup (Advanced)
- [ ] Open `AppDelegate.swift`
- [ ] Add this to `applicationDidFinishLaunching`:
```swift
if let window = NSApplication.shared.windows.first {
    let gameVC = GameViewController()
    window.contentViewController = gameVC
    window.makeKeyAndOrderFront(nil)
    window.setContentSize(NSSize(width: 1024, height: 768))
}
```

## ☐ Step 6: Fix the "Unsigned Child" Error

- [ ] Select your project (top of navigator)
- [ ] Select your app target
- [ ] Click **Build Phases** tab
- [ ] Expand **Copy Bundle Resources**
- [ ] Verify ALL these files are listed:
  - [ ] CrashBandicoot.obj
  - [ ] CrashBandicoot.mtl
  - [ ] CrashBody.png
  - [ ] CrashEye.png
  - [ ] CrashEyelid.png

If any are missing:
- [ ] Click the **+** button
- [ ] Find and add the missing files
- [ ] Click Add

## ☐ Step 7: Clean Build
- [ ] In Xcode menu: **Product → Clean Build Folder** (⇧⌘K)
- [ ] Wait for it to complete

## ☐ Step 8: Build Project
- [ ] Press ⌘B (or Product → Build)
- [ ] Check for errors in Issue Navigator
- [ ] All errors should be resolved

## ☐ Step 9: Run the Game!
- [ ] Press ⌘R (or Product → Run)
- [ ] Game window should appear
- [ ] You should see:
  - Green floor
  - Gray boundary walls
  - Your Crash Bandicoot character (or orange capsule placeholder)
  - Blue sky gradient

## ☐ Step 10: Test Controls
- [ ] Click on the game window to focus it
- [ ] Press **W** - character should move forward
- [ ] Press **S** - character should move backward
- [ ] Press **A** - character should move left
- [ ] Press **D** - character should move right
- [ ] Character should rotate to face movement direction
- [ ] Camera should smoothly follow character

---

## ✅ Success Criteria

You'll know it's working when:
- ✅ No build errors
- ✅ Game window opens
- ✅ You can see the environment (floor, walls, sky)
- ✅ Character is visible (either your model or placeholder)
- ✅ WASD keys move the character
- ✅ Camera follows the character smoothly
- ✅ Statistics show in top-right (FPS ~60)

---

## 🚨 Troubleshooting

### "Unsigned child" error still appears
→ Go back to Step 6, remove and re-add assets

### Character not visible
→ Check Console (⌘⇧C) for loading errors
→ Look for "Successfully loaded" or error messages
→ If placeholder appears, your .obj file isn't loading correctly

### Black screen
→ Check Console for errors
→ Verify GameViewController is set as window's content view
→ Try running in Debug mode with breakpoints

### No keyboard response
→ Click the game window to focus it
→ Check that `acceptsFirstResponder` returns true in GameViewController
→ Try clicking inside the window first

### Build errors
→ Ensure all Swift files are added to target
→ Check for any missing imports
→ Verify you selected AppKit (not SwiftUI)

### Character falls through floor
→ Check Console for physics setup messages
→ Verify floor physics body is created
→ Character should start at Y=2

---

## 📋 Final Verification Checklist

Before asking for help, verify:
- [ ] Xcode version is 14.0 or later
- [ ] macOS deployment target is 13.0 or later
- [ ] All 6 Swift files are in project and target
- [ ] All 5 asset files are in "Copy Bundle Resources"
- [ ] Target membership is checked for all files
- [ ] Build succeeds (⌘B shows no errors)
- [ ] You clicked the game window to focus it
- [ ] Console shows "Successfully loaded" message

---

## 🎉 Next Steps After Success

Once everything works:
1. Adjust character scale if needed (PlayerCharacter.swift line ~60)
2. Adjust camera distance (CameraController.swift line ~16)
3. Change movement speed (PlayerCharacter.swift line ~20)
4. Add jump functionality (see SUMMARY.md)
5. Start building your level!

---

**Total time to setup: ~10 minutes** ⏱️

If you get stuck on any step, check the detailed README.md for more information.

Good luck! 🚀

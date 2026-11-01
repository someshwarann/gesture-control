# Gesture Control for Mac

A menu bar app that lets you control your Mac with hand gestures, using Apple's built-in Vision hand tracking. Everything stays on your Mac: nothing is saved and nothing is uploaded.

## Build (one time, about 1 minute)
1. Open Terminal and run `xcode-select --install` (skip this if you already have Xcode or its Command Line Tools).
2. Unzip the folder, then run:
   ```
   cd ~/Downloads/gesture-control
   chmod +x build.sh && ./build.sh
   mv "build/Gesture Control.app" /Applications/
   open "/Applications/Gesture Control.app"
   ```
3. Allow **Camera** and **Accessibility** when macOS asks (System Settings → Privacy & Security). Then quit the app from its menu bar icon and reopen it.

Requires macOS 13 Ventura or newer. Works on Apple Silicon and Intel.

## Use
Press **⌥⌘G** (Option+Command+G) to start a session. The camera switches on and you hear a "tink". It turns fully off on its own after 5 seconds with no hand in view, or when you hold up a fist.

| Gesture | Action |
|---|---|
| ☝️ Point with your index finger | Move the cursor |
| 🤏 Pinch thumb and index | Click (hold to drag, pinch twice to double-click) |
| 👌 Touch thumb to middle finger | Right-click |
| ✌️ Two fingers up, move up/down | Scroll |
| 🖐 Palm swipe left/right | Switch desktops (Spaces) |
| 🖐 Palm swipe up / down | Mission Control / App Exposé |
| 🖐 Palm held still for 1 s | Play / pause |
| ✊ Fist held for 1 s | End the session (camera off) |

## Why it uses very little power
- **On-demand by default.** The camera is completely off until you press ⌥⌘G, and it shuts off again after 5 s idle. Idle draw is zero, with no background camera.
- **Low resolution and low fps.** Frames are 640×480 at 15 fps (10 fps in Low Power Mode), and late frames are dropped rather than queued.
- **Apple Neural Engine.** Vision's hand-pose model runs on the Mac's ML hardware instead of burning the CPU, so it's much lighter than OpenCV or MediaPipe in Python.
- **Always-on eco mode (optional).** The camera idles at 4 fps and only speeds up to 15 fps while a hand is in view.
- **Auto-off guards.** The camera stops when you lock the screen, the display sleeps, the Mac sleeps, or the battery drops below 15%. Always-on mode is blocked in Low Power Mode.

## Notes
- The green camera light is on whenever the camera is running. That's macOS's privacy indicator and it can't be hidden.
- If scrolling feels backwards, use **Reverse scroll** in the menu.
- Rebuilding the app changes its signature, so you may need to re-tick it under Accessibility afterwards.
- Desktop swipes need more than one Space (open Mission Control and press + to add one).
- The cursor follows the main display only.
- Tune it in `Sources/AppDelegate.swift` (fps, timeout) and `Sources/GestureEngine.swift` (pinch distance, swipe distance).

import AppKit
import AVFoundation
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    enum Mode: String { case onDemand, alwaysOn }

    private let tracker = HandTracker()
    private let engine = GestureEngine()
    private let hud = HUD()
    private var showHUD: Bool {
        get { defaults.object(forKey: "showHUD") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showHUD") }
    }
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private let defaults = UserDefaults.standard

    // Power tuning
    private let activeFPS: Int32 = 30        // while a hand is being tracked (fast response)
    private let ecoActiveFPS: Int32 = 20     // in Low Power Mode
    private let idleFPS: Int32 = 6           // always-on mode, no hand in view
    private let sessionIdleTimeout: TimeInterval = 5   // on-demand: camera off after 5 s with no hand

    private var mode: Mode {
        get { Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .onDemand }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }
    private var sounds: Bool {
        get { defaults.object(forKey: "sounds") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sounds") }
    }

    private var cameraOn = false
    private var paused = false              // always-on mode paused by the user / lock / battery
    private var handVisible = false
    private var lastHandSeen = Date.distantPast
    private var watchdog: Timer?

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.reverseScroll = defaults.bool(forKey: "reverseScroll")
        engine.onFist = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.mode == .onDemand else { return }
                self.stopCamera()
            }
        }
        engine.onStatus = { [weak self] text in
            DispatchQueue.main.async {
                guard let self = self, self.cameraOn, self.showHUD else { return }
                self.hud.show(text)
            }
        }
        tracker.onFrame = { [weak self] frame in
            guard let self = self else { return }
            self.engine.process(frame)
            let seen = frame != nil
            DispatchQueue.main.async { self.handFrame(seen: seen) }
        }

        // ⌥⌘G  (G = key code 5)
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | optionKey))
        hotKey?.action = { [weak self] in self?.hotKeyPressed() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        rebuildMenu()
        updateIcon()
        observeSystem()
        tracker.prepare()   // set up the camera pipeline now so ⌥⌘G starts instantly
        requestPermissions(prompt: true)

        if mode == .alwaysOn { startCamera() }
    }

    // MARK: Camera control

    private var currentActiveFPS: Int32 { Power.lowPowerMode ? ecoActiveFPS : activeFPS }

    private func startCamera() {
        guard !cameraOn else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            requestPermissions(prompt: true); return
        }
        if Power.batteryTooLow {
            notifyBlocked("Battery is below 15%, so the camera stays off to save power.")
            return
        }
        cameraOn = true
        paused = false
        lastHandSeen = Date()
        let fps = (mode == .alwaysOn) ? idleFPS : currentActiveFPS
        tracker.start(fps: fps)
        startWatchdog()
        if sounds { NSSound(named: NSSound.Name("Tink"))?.play() }
        if showHUD && mode == .onDemand { hud.show("👋 Show your hand") }
        updateIcon(); rebuildMenu()
    }

    private func stopCamera(paused userPaused: Bool = false) {
        guard cameraOn else { return }
        cameraOn = false
        paused = userPaused
        handVisible = false
        tracker.stop()
        engine.reset()
        watchdog?.invalidate(); watchdog = nil
        hud.hide()
        if sounds { NSSound(named: NSSound.Name("Pop"))?.play() }
        updateIcon(); rebuildMenu()
    }

    private func handFrame(seen: Bool) {
        guard cameraOn else { return }
        if seen {
            lastHandSeen = Date()
            if !handVisible {
                handVisible = true
                if mode == .alwaysOn { tracker.setFPS(currentActiveFPS) }   // wake up to full speed
                updateIcon()
            }
        }
    }

    /// Runs twice a second while the camera is on: idle shutdown, fps drop, battery guard.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.cameraOn else { return }
            let idle = Date().timeIntervalSince(self.lastHandSeen)
            switch self.mode {
            case .onDemand:
                if idle > self.sessionIdleTimeout { self.stopCamera() }
            case .alwaysOn:
                if self.handVisible && idle > 4 {
                    self.handVisible = false
                    self.tracker.setFPS(self.idleFPS)     // back to sipping power
                    self.hud.hide()
                    self.updateIcon()
                }
            }
            if Power.batteryTooLow {
                self.stopCamera(paused: true)
                self.notifyBlocked("Battery dropped below 15%, so gestures are paused.")
            }
        }
        watchdog?.tolerance = 0.2
    }

    private func hotKeyPressed() {
        if cameraOn { stopCamera(paused: mode == .alwaysOn) } else { startCamera() }
    }

    // MARK: System events (lock, sleep, display off)

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.systemPause() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.systemResume() }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.systemPause()
        }
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.systemResume()
        }
    }

    private var pausedBySystem = false
    private func systemPause() {
        if cameraOn { pausedBySystem = (mode == .alwaysOn); stopCamera() }
    }
    private func systemResume() {
        if pausedBySystem && mode == .alwaysOn && !cameraOn {
            pausedBySystem = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startCamera() }
        }
    }

    // MARK: Permissions

    @discardableResult
    private func requestPermissions(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let ax = AXIsProcessTrustedWithOptions(opts)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in DispatchQueue.main.async { self.rebuildMenu() } }
        case .denied, .restricted:
            if prompt {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            }
        default: break
        }
        return ax && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    // MARK: Menu bar UI

    private func updateIcon() {
        let symbol: String
        if !cameraOn { symbol = "hand.raised.slash" }
        else if handVisible || mode == .onDemand { symbol = "hand.raised.fill" }
        else { symbol = "hand.raised" }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Gesture Control")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let state: String
        if cameraOn { state = mode == .alwaysOn ? "Watching (eco)" : "Gesture session on" }
        else { state = (mode == .alwaysOn && paused) ? "Paused, camera off" : "Idle, camera off" }
        let header = NSMenuItem(title: "Gesture Control: \(state)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let toggleTitle: String
        if mode == .onDemand { toggleTitle = cameraOn ? "End session" : "Start gesture session" }
        else { toggleTitle = cameraOn ? "Pause" : "Resume" }
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleTapped), keyEquivalent: "g")
        toggle.keyEquivalentModifierMask = [.command, .option]
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        let od = NSMenuItem(title: "On-demand: ⌥⌘G, camera off after 5 s (lowest power)", action: #selector(setOnDemand), keyEquivalent: "")
        od.state = mode == .onDemand ? .on : .off; od.target = self
        menu.addItem(od)
        let ao = NSMenuItem(title: "Always on, eco (6 fps until a hand appears)", action: #selector(setAlwaysOn), keyEquivalent: "")
        ao.state = mode == .alwaysOn ? .on : .off; ao.target = self
        menu.addItem(ao)
        menu.addItem(.separator())

        let rs = NSMenuItem(title: "Reverse scroll", action: #selector(toggleReverse), keyEquivalent: "")
        rs.state = engine.reverseScroll ? .on : .off; rs.target = self
        menu.addItem(rs)
        let hudItem = NSMenuItem(title: "Show gesture indicator", action: #selector(toggleHUD), keyEquivalent: "")
        hudItem.state = showHUD ? .on : .off; hudItem.target = self
        menu.addItem(hudItem)
        let snd = NSMenuItem(title: "Sounds", action: #selector(toggleSounds), keyEquivalent: "")
        snd.state = sounds ? .on : .off; snd.target = self
        menu.addItem(snd)
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off; login.target = self
        menu.addItem(login)
        menu.addItem(.separator())

        let guide = NSMenuItem(title: "Gesture guide…", action: #selector(showGuide), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)
        let perms = NSMenuItem(title: "Check permissions…", action: #selector(checkPerms), keyEquivalent: "")
        perms.target = self
        menu.addItem(perms)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleTapped() { hotKeyPressed() }

    @objc private func setOnDemand() {
        if cameraOn { stopCamera() }
        mode = .onDemand; paused = false
        rebuildMenu(); updateIcon()
    }

    @objc private func setAlwaysOn() {
        if Power.lowPowerMode {
            notifyBlocked("Low Power Mode is on, so always-on stays off. Use ⌥⌘G instead.")
            return
        }
        if cameraOn { stopCamera() }
        mode = .alwaysOn
        startCamera()
        rebuildMenu()
    }

    @objc private func toggleReverse() {
        engine.reverseScroll.toggle()
        defaults.set(engine.reverseScroll, forKey: "reverseScroll")
        rebuildMenu()
    }

    @objc private func toggleHUD() { showHUD.toggle(); if !showHUD { hud.hide() }; rebuildMenu() }

    @objc private func toggleSounds() { sounds.toggle(); rebuildMenu() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { notifyBlocked("Couldn't change launch at login: \(error.localizedDescription)") }
        rebuildMenu()
    }

    @objc private func checkPerms() {
        let ok = requestPermissions(prompt: true)
        let a = NSAlert()
        a.messageText = ok ? "All set" : "Permissions needed"
        a.informativeText = ok
            ? "Camera and Accessibility are both allowed."
            : "Open System Settings → Privacy & Security and allow Gesture Control under both Camera and Accessibility. Then quit and reopen the app."
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc private func showGuide() {
        let a = NSAlert()
        a.messageText = "Gestures"
        a.informativeText = """
        ⌥⌘G  start / stop (camera turns fully off)

        ☝️  Point with your index finger to move the cursor
        🤏  Pinch thumb + index to click (hold to drag, twice for double-click)
        👌  Touch thumb to middle finger to right-click
        ✌️  Two fingers up, move hand up/down to scroll
        🖐  Open palm, swipe left/right to switch desktops
        🖐  Open palm, swipe up for Mission Control, down for App Exposé
        🖐  Hold an open palm still for 1 s to play/pause
        ✊  Hold a fist for 1 s to end the session

        Tip: keep your hand 40 to 70 cm from the camera in decent light.
        """
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func notifyBlocked(_ text: String) {
        let a = NSAlert()
        a.messageText = "Gesture Control"
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

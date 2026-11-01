import Foundation
import CoreGraphics

/// One Euro filter: smooths jitter when the hand is still, stays responsive when it moves.
struct OneEuro {
    var minCutoff = 2.0, beta = 0.05, dCutoff = 1.0   // tuned for low lag
    private var x: Double? = nil
    private var dx: Double = 0
    private var t: Double? = nil

    init() {}

    mutating func reset() { x = nil; t = nil; dx = 0 }

    mutating func filter(_ v: Double, _ ts: Double) -> Double {
        guard let px = x, let pt = t, ts > pt else { x = v; t = ts; return v }
        let dt = ts - pt
        func alpha(_ cutoff: Double) -> Double {
            let tau = 1.0 / (2.0 * Double.pi * cutoff)
            return 1.0 / (1.0 + tau / dt)
        }
        let rawDx = (v - px) / dt
        dx += alpha(dCutoff) * (rawDx - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let nx = px + alpha(cutoff) * (v - px)
        x = nx
        t = ts
        return nx
    }
}

/// Turns hand poses into Mac actions.
///
///  ☝️ Point (index up)             → move the cursor
///  🤏 Pinch thumb + index           → click (hold to drag, pinch twice = double-click)
///  Thumb + middle finger touch      → right-click
///  🫰 Snap (thumb + middle)          → quit every app and close every window
///  ✌️ Two fingers up, move up/down  → scroll
///  🖐 Open palm swipe left / right  → previous / next desktop (Space)
///  🖐 Open palm swipe up            → Mission Control
///  🖐 Open palm swipe down          → App Exposé
///  🖐 Open palm held still ~1 s     → play / pause
///  ✊ Fist held ~0.7 s              → end the gesture session (camera off)
final class GestureEngine {
    enum Pose { case none, pointer, scroll, palm, fist, other }

    var reverseScroll = false
    var onFist: (() -> Void)?
    /// Short status text for the on-screen indicator (called off the main thread).
    var onStatus: ((String) -> Void)?
    private var candidate: Pose = .none
    private var candidateFrames = 0
    private var lastMoveTarget: CGPoint?
    var snapEnabled = true
    var onSnap: (() -> Void)?
    private var midTouching = false
    private var midReleaseTime: TimeInterval?
    private var lastSnap: TimeInterval = 0

    private var fx = OneEuro(), fy = OneEuro()
    private var cursor: CGPoint?
    private var pinching = false
    private var pinchStart: TimeInterval = 0
    private var rightPinching = false
    private var lastClickTime: TimeInterval = 0
    private var clickCount: Int64 = 1
    private var lastScrollY: CGFloat?
    private var wristHistory: [(t: TimeInterval, p: CGPoint)] = []
    private var lastSwipe: TimeInterval = 0
    private var stillSince: TimeInterval?
    private var palmFired = false
    private var fistSince: TimeInterval?
    private var fistFired = false
    private var pose: Pose = .none
    private var lastFrameTime: TimeInterval = 0

    func reset() {
        if pinching {
            Input.mouse(.leftMouseUp, at: cursor ?? Input.currentCursor, button: .left, clicks: clickCount)
        }
        pinching = false
        rightPinching = false
        fx.reset(); fy.reset()
        lastScrollY = nil
        wristHistory.removeAll()
        stillSince = nil
        palmFired = false
        fistSince = nil
        fistFired = false
        pose = .none
        midTouching = false
        midReleaseTime = nil
        candidate = .none
        candidateFrames = 0
        lastMoveTarget = nil
    }

    func process(_ frame: HandFrame?) {
        guard let f = frame else { reset(); return }
        let p = f.points
        guard let wrist = p[.wrist], let middleMCP = p[.middleMCP], let indexMCP = p[.indexMCP],
              let thumbTip = p[.thumbTip],
              let indexTip = p[.indexTip], let indexPIP = p[.indexPIP],
              let middleTip = p[.middleTip], let middlePIP = p[.middlePIP],
              let ringTip = p[.ringTip], let ringPIP = p[.ringPIP],
              let littleTip = p[.littleTip], let littlePIP = p[.littlePIP] else { return }

        let scale = dist(wrist, middleMCP)          // hand size, so gestures work at any distance
        guard scale > 0.03 else { return }

        if f.time - lastFrameTime > 0.4 { fx.reset(); fy.reset(); wristHistory.removeAll() }
        lastFrameTime = f.time

        func extended(_ tip: CGPoint, _ pip: CGPoint) -> Bool {
            dist(tip, wrist) > dist(pip, wrist) * 1.12
        }
        let iE = extended(indexTip, indexPIP)
        let mE = extended(middleTip, middlePIP)
        let rE = extended(ringTip, ringPIP)
        let lE = extended(littleTip, littlePIP)

        // Pinch with hysteresis so it doesn't flicker.
        let pinchDist = dist(thumbTip, indexTip) / scale
        let wasPinching = pinching
        if pinching {
            if pinchDist > 0.38 { pinching = false }
        } else if pinchDist < 0.25 && !(mE && rE && lE) {
            pinching = true
        }

        let newPose: Pose
        if pinching || (iE && !mE && !rE && !lE) { newPose = .pointer }
        else if iE && mE && !rE && !lE { newPose = .scroll }
        else if iE && mE && rE && lE { newPose = .palm }
        else if !iE && !mE && !rE && !lE { newPose = .fist }
        else { newPose = .other }

        // Debounce: a new pose must hold for 2 frames (≈66 ms) so it doesn't flicker.
        // Pinching switches instantly so clicks never feel late.
        var stablePose = pose
        if newPose == pose { candidateFrames = 0 }
        else if pinching { stablePose = newPose }
        else {
            if newPose == candidate { candidateFrames += 1 } else { candidate = newPose; candidateFrames = 1 }
            if candidateFrames >= 2 { stablePose = newPose; candidateFrames = 0 }
        }

        if stablePose != pose {
            lastScrollY = nil
            wristHistory.removeAll()
            stillSince = nil
            palmFired = false
            fistSince = nil
            fistFired = false
            if pose == .pointer { fx.reset(); fy.reset(); lastMoveTarget = nil }
            pose = stablePose
            onStatus?(Self.label(for: pose))
        }

        // Thumb + middle finger: a quick release where the middle finger slaps down
        // into the palm is a SNAP (quit all apps). A gentle release is a right-click.
        let midDist = dist(thumbTip, middleTip) / scale
        if !pinching {
            if !midTouching && midDist < 0.25 { midTouching = true; midReleaseTime = nil }
            else if midTouching && midDist > 0.38 { midTouching = false; midReleaseTime = f.time }
        }
        if let r = midReleaseTime {
            let since = f.time - r
            if snapEnabled && !mE && since < 0.35 && f.time - lastSnap > 3 {
                midReleaseTime = nil
                lastSnap = f.time
                onStatus?("🫰 Snap! Closing everything")
                onSnap?()
            } else if since >= 0.2 && (mE || !snapEnabled) {
                midReleaseTime = nil
                if pose == .pointer {
                    Input.rightClick(at: cursor ?? Input.currentCursor)
                    onStatus?("👌 Right-click")
                }
            } else if since >= 0.4 {
                midReleaseTime = nil
            }
        }

        // Release a click/drag whatever pose the hand moved into.
        if wasPinching && !pinching {
            Input.mouse(.leftMouseUp, at: cursor ?? Input.currentCursor, button: .left, clicks: clickCount)
        }

        switch pose {
        case .pointer:
            // Follow the index knuckle: it stays steady while you pinch.
            let target = mapToScreen(indexMCP)
            let c = CGPoint(x: fx.filter(Double(target.x), f.time),
                            y: fy.filter(Double(target.y), f.time))
            let frozen = pinching && f.time - pinchStart < 0.08   // hold still right after a click
            let moved = lastMoveTarget.map { dist($0, c) >= 1.5 } ?? true   // ignore sub-pixel jitter
            if !frozen && moved {
                cursor = c
                lastMoveTarget = c
                Input.move(to: c, dragging: pinching && wasPinching)
            }
            if pinching && !wasPinching {
                pinchStart = f.time
                clickCount = (f.time - lastClickTime < 0.45) ? min(clickCount + 1, 3) : 1
                lastClickTime = f.time
                Input.mouse(.leftMouseDown, at: cursor ?? c, button: .left, clicks: clickCount)
                onStatus?(clickCount > 1 ? "🤏 Double-click" : "🤏 Click")
            }

        case .scroll:
            let y = indexMCP.y
            if let ly = lastScrollY {
                var d = (y - ly) * 3000
                if reverseScroll { d = -d }
                if abs(d) > 1 { Input.scroll(Int32(d.rounded())) }
            }
            lastScrollY = y

        case .palm:
            wristHistory.append((f.time, wrist))
            wristHistory.removeAll { f.time - $0.t > 0.3 }
            if let first = wristHistory.first, f.time - first.t > 0.08, f.time - lastSwipe > 0.6 {
                let dx = wrist.x - first.p.x
                let dy = wrist.y - first.p.y
                if abs(dx) > 0.16 && abs(dx) > 1.6 * abs(dy) {
                    Input.key(dx > 0 ? Input.right : Input.left, flags: .maskControl)
                    onStatus?(dx > 0 ? "➡️ Next desktop" : "⬅️ Previous desktop")
                    lastSwipe = f.time; wristHistory.removeAll(); stillSince = nil
                    return
                }
                if abs(dy) > 0.16 && abs(dy) > 1.6 * abs(dx) {
                    Input.key(dy > 0 ? Input.up : Input.down, flags: .maskControl)
                    onStatus?(dy > 0 ? "⬆️ Mission Control" : "⬇️ App Exposé")
                    lastSwipe = f.time; wristHistory.removeAll(); stillSince = nil
                    return
                }
            }
            // Palm held still → play/pause, once per hold.
            let spread = wristHistory.map { dist($0.p, wrist) }.max() ?? 1
            let covered = (wristHistory.last?.t ?? 0) - (wristHistory.first?.t ?? 0)
            if spread < 0.025 && covered > 0.2 {
                if stillSince == nil { stillSince = f.time }
                if !palmFired, let s = stillSince, f.time - s > 0.7 {
                    Input.playPause()
                    onStatus?("⏯ Play / Pause")
                    palmFired = true
                }
            } else {
                stillSince = nil
            }

        case .fist:
            if fistSince == nil { fistSince = f.time }
            if !fistFired, let s = fistSince, f.time - s > 0.5 {
                fistFired = true
                onFist?()
            }

        case .none, .other:
            break
        }
    }

    static func label(for pose: Pose) -> String {
        switch pose {
        case .pointer: return "☝️ Moving cursor"
        case .scroll: return "✌️ Scrolling"
        case .palm: return "🖐 Swipe, or hold to play/pause"
        case .fist: return "✊ Hold to stop"
        case .other: return "✋ Hand seen"
        case .none: return "👋 Show your hand"
        }
    }

    /// Uses the middle of the camera view so you don't have to stretch to reach screen edges.
    private func mapToScreen(_ pt: CGPoint) -> CGPoint {
        let b = CGDisplayBounds(CGMainDisplayID())
        let nx = clamp((pt.x - 0.2) / 0.6)
        let ny = clamp((pt.y - 0.25) / 0.55)
        return CGPoint(x: b.minX + nx * (b.width - 1), y: b.minY + (1 - ny) * (b.height - 1))
    }
}

func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
func clamp(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }

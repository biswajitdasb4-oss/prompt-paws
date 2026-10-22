import AppKit

/// Where the pet may go. Chosen in the menu and remembered between launches.
///  roam:  walks around now and then, mostly rests.
///  stay:  never walks; idles, looks around, sits, waves in place.
///  sleep: lies down and stays asleep until you click it or pick another mode.
enum PetMode: String { case roam, stay, sleep }

/// Decides where the pet goes and what it does. It moves the window and tells the page which clip to
/// play; the page only draws. Claude's status is shown by the bubble (set by AppDelegate); here it
/// only adds small reactions: waves when a session needs you, cheers once when one is done.
final class Brain {
    enum Activity: String {
        case idle, look, think, walk, run, follow, approach, sit, sleep, wake, emote, wave, cheer, dragged, land
    }

    private let panel: PetPanel
    private let view: PetView

    // Layout reported by the page (CSS pixels = points, origin at the window's top-left).
    private var foot = CGPoint(x: 110, y: 190)
    private var hit = CGRect(x: 60, y: 60, width: 100, height: 130)
    private var bodyHeight: CGFloat = 130
    private var walkSpeed: CGFloat = 0.9   // body heights per second
    private var runSpeed: CGFloat = 2.2
    private(set) var keys: [String: Double] = [:]   // behaviour key -> clip length (s)
    private(set) var ready = false

    private(set) var feet: CGPoint            // screen point under the feet (y up)
    private(set) var activity: Activity = .idle
    private(set) var mode: PetMode = .roam
    private(set) var modeBeforeSleep: PetMode = .roam
    private(set) var claude = ClaudeSummary()
    private var until: TimeInterval = 0
    private var target: CGPoint?
    private var clip = ""
    private var facing: CGFloat = 0
    private var fps = -1
    private var sleepingShown = false
    private var approached = false     // already walked to the pointer for the current "needs you"
    private var celebrating = false
    private var lastTick = CACurrentMediaTime()
    private var idleCheckAt: TimeInterval = 0
    private var userIdle: TimeInterval = 0
    private var followResting = false
    private var pressed = false
    private var dragging = false
    private var dragStart = CGPoint.zero
    private var dragOffset = CGVector.zero
    private var clicks = 0

    var autopilot = true               // the self-test turns this off to play clips by hand
    var napAfter: TimeInterval = 180   // seconds without keyboard/mouse input before a nap
    var onSave: (() -> Void)?          // mode or place changed: remember it
    var onOpenClaude: ((ClaudeSession) -> Void)?   // clicked while a session needs you or it's your turn: show it
    private(set) var paused = false
    private(set) var hidden = false

    init(panel: PetPanel, view: PetView) {
        self.panel = panel
        self.view = view
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        feet = CGPoint(x: vf.maxX - 240, y: vf.minY + 12)
    }

    /// Puts the pet back where it was last time (called before the character loads).
    func restore(mode: PetMode, modeBeforeSleep: PetMode, feet: CGPoint?) {
        self.mode = mode
        self.modeBeforeSleep = modeBeforeSleep == .sleep ? .roam : modeBeforeSleep
        if let feet { self.feet = feet }
    }

    // MARK: - Messages from the page

    func layoutChanged(foot: CGPoint, hit: CGRect, height: CGFloat) {
        self.foot = foot
        self.hit = hit
        bodyHeight = max(40, height)
        place()
    }

    func characterReady(walkSpeed: Double, runSpeed: Double, keys: [String: Double]) {
        self.walkSpeed = CGFloat(walkSpeed)
        self.runSpeed = CGFloat(runSpeed)
        self.keys = keys
        ready = true
        clip = ""
        fps = -1
        facing = 0
        sleepingShown = false
        feet = clamp(feet)
        place()
        if autopilot {
            if mode == .sleep { start(.sleep) } else { start(.idle, for: 1.5) }
        }
        applyFps()
    }

    func characterUnloaded() { ready = false }

    func clipFinished(_ key: String) {
        guard autopilot, ready, key == clip else { return }
        switch activity {
        case .emote, .land, .wake, .wave: next()
        default: break
        }
    }

    // MARK: - Every frame (30 Hz)

    func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastTick, 0.1))
        lastTick = now
        updateHover()
        guard ready, !hidden, !paused, autopilot, !dragging else { return }

        if now >= idleCheckAt {
            userIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            idleCheckAt = now + 1
        }
        if activity == .sleep {
            if mode != .sleep, userIdle < 1.5 { start(.wake) }   // a nap ends when you are back
            return                                                // sleep mode: only you can wake it
        }
        if mode == .sleep, activity != .land {
            start(.sleep)   // e.g. dropped somewhere new: lie down again
            return
        }
        let calm: Set<Activity> = [.idle, .look, .think, .sit, .walk, .run, .follow, .emote]
        if userIdle > napAfter, calm.contains(activity) {
            start(.sleep)   // you are away: take a nap
            return
        }

        switch activity {
        case .walk, .run, .follow, .approach: move(dt)
        default: break
        }
        if now >= until { next() }
    }

    private func move(_ dt: CGFloat) {
        let chasing = activity == .follow || activity == .approach
        let goal = chasing ? besideMouse() : (target ?? feet)
        let dx = goal.x - feet.x
        let dy = goal.y - feet.y
        let d = hypot(dx, dy)

        if activity == .follow, followResting {
            if d < bodyHeight * 0.5 { return }
            followResting = false
        }
        if d <= 3 {
            switch activity {
            case .approach: start(.wave)
            case .follow:
                followResting = true
                play("idle")
                face(0)
            default: next()
            }
            return
        }

        let fast = chasing ? d > bodyHeight * 5 : activity == .run
        let speed = (fast ? runSpeed : walkSpeed) * bodyHeight
        let step = min(speed * dt, d)
        feet.x += dx / d * step
        feet.y += dy / d * step
        play(fast ? "run" : "walk")
        face(atan2(dx, -dy))
        place()
    }

    /// Stand next to the pointer, not on it (so the pet does not catch the user's clicks).
    private func besideMouse() -> CGPoint {
        let m = NSEvent.mouseLocation
        let side: CGFloat = feet.x < m.x ? -1 : 1
        return clamp(CGPoint(x: m.x + side * bodyHeight * 0.55, y: m.y - bodyHeight * 0.45))
    }

    // MARK: - Choosing what to do next

    private func next() {
        if activity == .sit {
            start(.wake)   // stand up before doing anything else
            return
        }
        if mode == .sleep {
            start(.sleep)
            return
        }
        if celebrating {
            celebrating = false
            start(.emote, key: "thumbs")
            return
        }
        if !claude.needsYou.isEmpty {
            attention()
            return
        }
        let roam = mode == .roam
        let r = Int.random(in: 0..<100)
        if !claude.working.isEmpty {
            // Claude is working: stay calm (the bubble says what is going on).
            switch r {
            case ..<12 where roam: start(.walk, to: randomPoint(near: 160))
            case ..<55: start(.think, for: .random(in: 3...6))
            case ..<80: start(.look, for: .random(in: 3...5))
            case ..<90: start(.emote, key: "nod")
            default: start(.idle, for: .random(in: 2...4))
            }
            return
        }
        if !roam {
            switch r {
            case ..<40: start(.idle, for: .random(in: 4...8))
            case ..<65: start(.look)
            case ..<87: start(.sit, for: .random(in: 15...40))
            default: start(.emote, key: ["nod", "wave", "dance", "thumbs"].randomElement()!)
            }
            return
        }
        switch r {
        case ..<22: start(.walk, to: Int.random(in: 0..<10) < 7 ? randomPoint(near: 300) : randomPoint())
        case ..<50: start(.idle, for: .random(in: 3...8))
        case ..<65: start(.look)
        case ..<80: start(.sit, for: .random(in: 15...40))
        case ..<84: start(.follow)
        case ..<87: start(.run, to: randomPoint(near: 500))
        default: start(.emote, key: ["dance", "jump", "wave", "thumbs", "nod"].randomElement()!)
        }
    }

    /// A session needs you: walk over once (roam mode only), then wave every few seconds.
    private func attention() {
        if mode == .roam, !approached {
            approached = true
            let goal = besideMouse()
            if hypot(goal.x - feet.x, goal.y - feet.y) > bodyHeight * 1.2 {
                start(.approach)
                return
            }
        }
        if activity == .wave { start(.idle, for: .random(in: 3...5)) } else { start(.wave) }
    }

    /// New Claude status from AppDelegate. `newNeeds`: a session just started waiting for you;
    /// `newReady`: a session just finished its turn.
    func claudeChanged(_ summary: ClaudeSummary, newNeeds: Bool, newReady: Bool) {
        let hadNeeds = !claude.needsYou.isEmpty
        claude = summary
        if newNeeds { approached = false }
        guard ready, autopilot, !dragging, !paused, !hidden, mode != .sleep, activity != .sleep else { return }
        if newNeeds {
            next()
        } else if newReady {
            celebrating = true
            start(.cheer, for: 3.4)
        } else if hadNeeds, summary.needsYou.isEmpty, [.approach, .wave].contains(activity) {
            next()   // you answered: stop waving
        }
    }

    private func start(_ a: Activity, for seconds: TimeInterval? = nil, to point: CGPoint? = nil, key: String? = nil) {
        let now = CACurrentMediaTime()
        activity = a
        target = point.map(clamp)
        followResting = false
        switch a {
        case .idle:
            play("idle"); face(0); until = now + (seconds ?? .random(in: 2...5))
        case .look:
            play("look"); face(0); until = now + (seconds ?? .random(in: 3...5))
        case .think:
            play("think"); face(0); until = now + (seconds ?? 4)
        case .sit:
            play("sit"); face(0); until = now + (seconds ?? .random(in: 15...40))
        case .walk, .run:
            let p = target ?? randomPoint()
            target = p
            let speed = (a == .run ? runSpeed : walkSpeed) * bodyHeight
            until = now + Double(hypot(p.x - feet.x, p.y - feet.y) / max(speed, 1)) + 3
        case .follow:
            until = now + (seconds ?? .random(in: 6...10))
        case .approach:
            until = now + 20
        case .sleep:
            play("sleep"); face(0); until = .infinity
        case .wake:
            play("wake", restart: true); face(0); until = now + length("wake") + 0.3
        case .wave:
            play("wave", restart: true); face(0); until = now + length("wave") + 0.3
        case .emote:
            let k = key ?? "nod"
            play(k, restart: true); face(0); until = now + length(k) + 0.3
        case .cheer:
            play("cheer"); face(0); until = now + (seconds ?? 3.4)
        case .land:
            play("land", restart: true); until = now + length("land") + 0.3
        case .dragged:
            play("dangle"); face(0); until = .infinity
        }
        if (a == .sleep) != sleepingShown {
            sleepingShown = a == .sleep
            view.js("pet.setSleeping(\(sleepingShown))")
        }
        applyFps()
    }

    // MARK: - Modes

    func setMode(_ m: PetMode) {
        if m == .sleep, mode != .sleep { modeBeforeSleep = mode }
        mode = m
        onSave?()
        guard ready, autopilot, !paused, !dragging else { return }
        switch m {
        case .sleep:
            start(.sleep)
        case .stay, .roam:
            if activity == .sleep {
                start(.wake)
            } else if m == .stay, [.walk, .run, .follow, .approach].contains(activity) {
                start(.idle, for: 2)
            }
        }
    }

    // MARK: - Mouse: click, drag and drop

    func mouseDown(at p: CGPoint) {
        pressed = true
        dragging = false
        dragStart = p
        dragOffset = CGVector(dx: feet.x - p.x, dy: feet.y - p.y)
    }

    func mouseDragged(to p: CGPoint) {
        guard pressed, ready else { return }
        if !dragging {
            guard hypot(p.x - dragStart.x, p.y - dragStart.y) > 4 else { return }
            dragging = true
            if !paused { start(.dragged) }
        }
        feet = CGPoint(x: p.x + dragOffset.dx, y: p.y + dragOffset.dy)
        place()
    }

    func mouseUp(at p: CGPoint) {
        pressed = false
        guard ready else { return }
        if dragging {
            dragging = false
            if !paused { start(.land) }
            onSave?()
        } else if let s = claude.needsYou.min(by: { $0.at < $1.at }) ?? claude.ready.min(by: { $0.at < $1.at }) {
            // A session needs you, else it's your turn in one: show the one waiting longest.
            // The mode stays (asleep stays asleep).
            onOpenClaude?(s)
            if !paused, activity != .sleep { start(.wave) }
        } else if !paused {
            clicked()
        }
    }

    private func clicked() {
        if activity == .sleep {
            if mode == .sleep { setMode(modeBeforeSleep) } else { start(.wake) }
            return
        }
        clicks += 1
        start(.emote, key: ["wave", "jump", "nod", "dance"][clicks % 4])
    }

    /// Clicks on the pet are ours; clicks anywhere else pass through to the app below.
    private func updateHover() {
        guard !hidden else { return }
        let inside = pressed || hitOnScreen.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }

    // MARK: - Menu actions

    func setPaused(_ on: Bool) {
        paused = on
        lastTick = CACurrentMediaTime()
        applyFps()
        if !on, ready, autopilot { next() }
    }

    func setHidden(_ on: Bool) {
        hidden = on
        if on {
            panel.orderOut(nil)
        } else {
            feet = clamp(feet)
            place()
            panel.orderFrontRegardless()
        }
        applyFps()
    }

    func screensChanged() {
        feet = clamp(feet)
        place()
    }

    /// Self-test: play one clip by hand.
    func debugPlay(_ key: String) { play(key, restart: true) }

    // MARK: - Helpers

    private func play(_ key: String, restart: Bool = false) {
        if key == clip, !restart { return }
        clip = key
        view.js("pet.play('\(key)')")
    }

    private func face(_ angle: CGFloat) {
        if abs((angle - facing).remainder(dividingBy: 2 * .pi)) < 0.05 { return }
        facing = angle
        view.js("pet.face(\(Double(angle)))")
    }

    private func applyFps() {
        let want = (hidden || paused) ? 0 : (activity == .sleep ? 10 : 30)
        guard want != fps else { return }
        fps = want
        view.js("pet.setFps(\(want))")
    }

    private func length(_ key: String) -> TimeInterval { keys[key] ?? 1.5 }

    private var screen: NSScreen {
        NSScreen.screens.first { $0.frame.contains(feet) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Where the feet may go: inside the visible screen, the head and the status bubble below the
    /// menu bar, not under the Dock.
    private var bounds: CGRect {
        let vf = screen.visibleFrame
        let half = max(hit.width / 2, bodyHeight * 0.35)
        return CGRect(x: vf.minX + half, y: vf.minY + 2,
                      width: max(1, vf.width - 2 * half), height: max(1, vf.height - bodyHeight * 1.45 - 2))
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        let b = bounds
        return CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }

    private func randomPoint(near r: CGFloat? = nil) -> CGPoint {
        if let r {
            return clamp(CGPoint(x: feet.x + .random(in: -r...r), y: feet.y + .random(in: -r * 0.6...r * 0.6)))
        }
        let b = bounds
        return CGPoint(x: .random(in: b.minX...b.maxX), y: .random(in: b.minY...b.maxY))
    }

    var hitOnScreen: CGRect {
        let f = panel.frame
        return CGRect(x: f.minX + hit.minX, y: f.minY + f.height - hit.maxY, width: hit.width, height: hit.height)
    }

    private func place() {
        let size = panel.frame.size
        let scale = screen.backingScaleFactor
        let x = ((feet.x - foot.x) * scale).rounded() / scale
        let y = ((feet.y - (size.height - foot.y)) * scale).rounded() / scale
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

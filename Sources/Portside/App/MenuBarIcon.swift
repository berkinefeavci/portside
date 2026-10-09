import AppKit

/// What the menu bar glyph shows: a little browser window with the number of
/// running servers inside it.
struct MenuBarIconState: Equatable {
    var count = 0
    var previousCount = 0
    /// 0…1 while the number rolls from `previousCount` to `count`.
    var roll: CGFloat = 1
    /// 0…1 position of the loading bar in the title bar, if one is running.
    var sweep: CGFloat?
}

enum MenuBarIconRenderer {
    static let menuBarSize = NSSize(width: 22, height: 16)

    static func image(_ state: MenuBarIconState, size: NSSize = menuBarSize) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            draw(state, in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Portside"
        return image
    }

    private static func draw(_ state: MenuBarIconState, in rect: NSRect) {
        let k = rect.height / 16
        let frame = NSRect(x: 1.5 * k, y: 1.2 * k, width: rect.width - 3 * k, height: rect.height - 2.4 * k)
        let window = NSBezierPath(roundedRect: frame, xRadius: 3.2 * k, yRadius: 3.2 * k)
        let ink = NSColor.black.withAlphaComponent(state.count == 0 && state.roll >= 1 ? 0.55 : 1)
        ink.set()

        window.lineWidth = 1.5 * k
        window.stroke()

        let titleBottom = frame.minY + 4.3 * k
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: frame.minX, y: titleBottom))
        divider.line(to: NSPoint(x: frame.maxX, y: titleBottom))
        divider.lineWidth = 1.2 * k
        divider.stroke()

        NSGraphicsContext.saveGraphicsState()
        window.addClip()
        if let sweep = state.sweep {
            // A page-load bar running across the title bar.
            let width = frame.width * 0.45
            let x = frame.minX - width + (frame.width + width) * sweep
            NSBezierPath(rect: NSRect(x: x, y: frame.minY, width: width, height: titleBottom - frame.minY)).fill()
        } else {
            NSBezierPath(ovalIn: NSRect(x: frame.minX + 1.9 * k, y: frame.minY + 1.25 * k, width: 1.6 * k, height: 1.6 * k)).fill()
        }

        let body = NSRect(x: frame.minX, y: titleBottom, width: frame.width, height: frame.maxY - titleBottom)
        NSBezierPath(rect: body).addClip()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.4 * k, weight: .heavy)
        let roll = min(max(state.roll, 0), 1)
        drawNumber(state.previousCount, in: body, offset: -body.height * roll, font: font, ink: ink)
        drawNumber(state.count, in: body, offset: body.height * (1 - roll), font: font, ink: ink)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawNumber(_ number: Int, in body: NSRect, offset: CGFloat, font: NSFont, ink: NSColor) {
        guard number > 0, abs(offset) < body.height else { return }
        let text = number > 99 ? "99+" : "\(number)"
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let size = (text as NSString).size(withAttributes: attributes)
        let point = NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2 + offset + 0.2)
        (text as NSString).draw(at: point, withAttributes: attributes)
    }
}

/// Drives the glyph: the number rolls when it changes, counts up on hover,
/// and a loading bar runs while a server is starting.
@MainActor
final class MenuBarIconAnimator {
    private weak var button: NSStatusBarButton?
    private var state = MenuBarIconState()
    private var target = 0
    private var steps: [Int] = []
    private var rollStart: Date?
    private var sweepStart: Date?
    private var isBusy = false
    private var timer: Timer?

    private static let rollDuration: TimeInterval = 0.22
    private static let countStepDuration: TimeInterval = 0.16
    private static let sweepDuration: TimeInterval = 0.8

    init(button: NSStatusBarButton?) {
        self.button = button
        render()
    }

    func update(count: Int, busy: Bool) {
        if count != target {
            target = count
            steps = [count]
            if rollStart == nil { startNextStep(duration: Self.rollDuration) }
        }
        if busy != isBusy {
            isBusy = busy
            if busy, sweepStart == nil { sweepStart = Date() }
        }
        run()
    }

    /// Counts up to the current number, like a page loading its contents.
    func hover() {
        guard rollStart == nil, steps.isEmpty else { return }
        sweepStart = sweepStart ?? Date()
        if target > 0 {
            state.count = 0
            state.previousCount = 0
            steps = target <= 6 ? Array(1...target) : [target]
            startNextStep(duration: Self.countStepDuration)
        }
        run()
    }

    private func startNextStep(duration: TimeInterval) {
        guard !steps.isEmpty else { rollStart = nil; return }
        state.previousCount = state.count
        state.count = steps.removeFirst()
        state.roll = 0
        rollStart = Date()
        currentRollDuration = duration
    }

    private var currentRollDuration = MenuBarIconAnimator.rollDuration

    private func run() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let now = Date()

        if let start = rollStart {
            let progress = now.timeIntervalSince(start) / currentRollDuration
            state.roll = CGFloat(easeOut(min(progress, 1)))
            if progress >= 1 {
                rollStart = nil
                if !steps.isEmpty { startNextStep(duration: currentRollDuration) }
            }
        }

        if let start = sweepStart {
            let progress = now.timeIntervalSince(start) / Self.sweepDuration
            if progress >= 1 {
                sweepStart = isBusy ? now : nil
                state.sweep = isBusy ? 0 : nil
            } else {
                state.sweep = CGFloat(progress)
            }
        }

        render()
        if rollStart == nil, sweepStart == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    private func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    private func render() {
        button?.image = MenuBarIconRenderer.image(state)
    }
}

/// Mouse-enter events for the status item button.
final class HoverTarget: NSResponder {
    var onEnter: () -> Void = {}
    override func mouseEntered(with event: NSEvent) { onEnter() }
}

import Cocoa
import ServiceManagement
import IOKit

// FakeBattery: a menu bar battery indicator styled after the macOS Tahoe battery menu.
// Real NSStatusItem, so it lives in the native menu bar (Cmd-drag to reorder).

let menuWidth: CGFloat = 286

// MARK: - Energy mode

enum EnergyMode: Int {
    case automatic = 0, low, high

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .low: return "Low Power"
        case .high: return "High Power"
        }
    }
}

/// Small battery glyph used inside the Energy Mode circles.
func energyGlyph(_ mode: EnergyMode, color: NSColor) -> NSImage {
    let size = NSSize(width: 15, height: 9)
    return NSImage(size: size, flipped: false) { _ in
        color.setStroke()
        color.setFill()
        let body = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 12.5, height: 8),
                                xRadius: 2.2, yRadius: 2.2)
        body.lineWidth = 1
        body.stroke()
        NSBezierPath(roundedRect: NSRect(x: 13.6, y: 3, width: 1.2, height: 3),
                     xRadius: 0.6, yRadius: 0.6).fill()
        switch mode {
        case .automatic:
            NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 9.5, height: 5),
                         xRadius: 1, yRadius: 1).fill()
        case .low:
            NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 3.5, height: 5),
                         xRadius: 1, yRadius: 1).fill()
        case .high:
            for i in 0..<3 {
                let x = 2.6 + CGFloat(i) * 3.0
                let t = NSBezierPath()
                t.move(to: NSPoint(x: x, y: 2.2))
                t.line(to: NSPoint(x: x, y: 6.8))
                t.line(to: NSPoint(x: x + 2.4, y: 4.5))
                t.close()
                t.fill()
            }
        }
        return true
    }
}

// MARK: - Menu row views

/// A plain text row (optionally with right-aligned text), like the header rows in the system menu.
final class LabelRowView: NSView {
    let leftLabel = NSTextField(labelWithString: "")
    let rightLabel = NSTextField(labelWithString: "")

    init(left: String, right: String = "", font: NSFont, color: NSColor,
         rightColor: NSColor = .labelColor, height: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: height))
        autoresizingMask = [.width]
        let y = (height - 17) / 2

        leftLabel.stringValue = left
        leftLabel.font = font
        leftLabel.textColor = color
        let leftWidth = right.isEmpty ? menuWidth - 28 : menuWidth - 28 - 56
        leftLabel.frame = NSRect(x: 14, y: y, width: leftWidth, height: 17)
        leftLabel.autoresizingMask = [.width]

        rightLabel.stringValue = right
        rightLabel.font = NSFont.systemFont(ofSize: 13)
        rightLabel.textColor = rightColor
        rightLabel.alignment = .right
        rightLabel.frame = NSRect(x: menuWidth - 14 - 56, y: y, width: 56, height: 17)
        rightLabel.autoresizingMask = [.minXMargin]

        addSubview(leftLabel)
        addSubview(rightLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// One Energy Mode row: round icon + title, with a hover highlight.
final class EnergyRowView: NSView {
    let mode: EnergyMode
    var onSelect: ((EnergyMode) -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    init(mode: EnergyMode) {
        self.mode = mode
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 34))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func resetHover() { hovering = false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { /* handled on mouse up */ }

    override func mouseUp(with event: NSEvent) {
        onSelect?(mode)
        enclosingMenuItem?.menu?.cancelTracking()
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 9, yRadius: 9).fill()
        }

        let d: CGFloat = 24
        let circle = NSRect(x: 14, y: (bounds.height - d) / 2, width: d, height: d)
        (isSelected ? NSColor.systemBlue : NSColor.labelColor.withAlphaComponent(0.1)).setFill()
        NSBezierPath(ovalIn: circle).fill()

        let glyph = energyGlyph(mode, color: isSelected ? .white : NSColor.labelColor.withAlphaComponent(0.8))
        glyph.draw(in: NSRect(x: circle.midX - 7.5, y: circle.midY - 4.5, width: 15, height: 9))

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]
        let title = mode.title as NSString
        let size = title.size(withAttributes: attrs)
        title.draw(at: NSPoint(x: 14 + d + 8, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

// MARK: - Driver bridge

/// Talks to FakeBatteryDriver.kext (if it is installed) through IOKit.
final class DriverBridge {
    private var service: io_service_t = 0
    private var lastSent: NSDictionary?

    /// True when the kext's "FakeBatteryManager" service is present in the IORegistry.
    var isConnected: Bool { ensureService() }

    private func ensureService() -> Bool {
        if service != 0 { return true }
        let found = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("FakeBatteryManager"))
        guard found != 0 else { return false }
        service = found
        lastSent = nil          // force a full push after (re)connecting
        return true
    }

    func push(percent: Int, charging: Bool, timeRemaining: Int, floor: Int) {
        guard ensureService() else { return }
        let state: NSDictionary = [
            "FBPercent": percent,
            "FBCharging": charging,
            "FBTimeRemaining": timeRemaining,
            "FBFloor": floor
        ]
        if lastSent?.isEqual(state) == true { return }   // nothing changed
        let result = IORegistryEntrySetCFProperties(service, state)
        if result == KERN_SUCCESS {
            lastSent = state
        } else {
            IOObjectRelease(service)
            service = 0
            lastSent = nil
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let defaults = UserDefaults.standard

    private var percent = 80
    private var charging = false
    private var showPercent = true
    private var energy = EnergyMode.automatic
    private var simulating = false
    private var warningsEnabled = true
    private var minutesPerPercent = 10.0   // while discharging: -1% every this many minutes
    private var minutesPerChargePercent = 5.0   // while charging: +1% every this many minutes
    private var showingWarning = false
    private var showOwnIcon = true
    private var floorPercent = 3            // lowest level the driver ever shows macOS (safety)
    private let driver = DriverBridge()
    private var timer: Timer?

    // Menu
    private let menu = NSMenu()
    private var headerRow: LabelRowView!
    private var sourceRow: LabelRowView!
    private var energyRows: [EnergyRowView] = []

    // Settings window
    private var settingsWindow: NSWindow?
    private var wSlider: NSSlider!
    private var wField: NSTextField!
    private var wCharging: NSButton!
    private var wShow: NSButton!
    private var wSim: NSButton!
    private var wWarn: NSButton!
    private var wMinutes: NSTextField!
    private var wChargeMinutes: NSTextField!
    private var wLogin: NSButton!
    private var wShowIcon: NSButton!
    private var wFloor: NSTextField!
    private var wDriver: NSTextField!

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if defaults.object(forKey: "percent") != nil { percent = defaults.integer(forKey: "percent") }
        charging = defaults.bool(forKey: "charging")
        if defaults.object(forKey: "showPercent") != nil { showPercent = defaults.bool(forKey: "showPercent") }
        energy = EnergyMode(rawValue: defaults.integer(forKey: "energy")) ?? .automatic
        simulating = defaults.bool(forKey: "simulating")
        if defaults.object(forKey: "warnings") != nil { warningsEnabled = defaults.bool(forKey: "warnings") }
        if defaults.object(forKey: "minutesPerPercent") != nil {
            minutesPerPercent = max(0.1, defaults.double(forKey: "minutesPerPercent"))
        }
        if defaults.object(forKey: "minutesPerChargePercent") != nil {
            minutesPerChargePercent = max(0.1, defaults.double(forKey: "minutesPerChargePercent"))
        }
        if defaults.object(forKey: "showOwnIcon") != nil { showOwnIcon = defaults.bool(forKey: "showOwnIcon") }
        if defaults.object(forKey: "floorPercent") != nil {
            floorPercent = max(0, min(50, defaults.integer(forKey: "floorPercent")))
        }

        statusItem.autosaveName = "FakeBatteryStatusItem"   // remembers where you drag it
        buildMenu()
        statusItem.menu = menu
        refresh()
        restartTimer()
    }

    func menuWillOpen(_ menu: NSMenu) {
        energyRows.forEach { $0.resetHover() }
        refresh()
    }

    // MARK: Menu

    private func customItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        headerRow = LabelRowView(left: "Battery", right: "\(percent)%",
                                 font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                 color: .labelColor, height: 28)
        sourceRow = LabelRowView(left: "Power Source: Battery",
                                 font: NSFont.systemFont(ofSize: 13),
                                 color: .secondaryLabelColor, height: 24)
        menu.addItem(customItem(headerRow))
        menu.addItem(customItem(sourceRow))
        menu.addItem(.separator())

        menu.addItem(customItem(LabelRowView(left: "Energy Mode",
                                             font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                             color: .secondaryLabelColor, height: 26)))
        for mode in [EnergyMode.automatic, .low, .high] {
            let row = EnergyRowView(mode: mode)
            row.onSelect = { [weak self] m in self?.setEnergy(m) }
            energyRows.append(row)
            menu.addItem(customItem(row))
        }
        menu.addItem(.separator())

        menu.addItem(customItem(LabelRowView(left: "No Apps Using Significant Energy",
                                             font: NSFont.systemFont(ofSize: 13),
                                             color: .secondaryLabelColor, height: 26)))
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Battery Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    // MARK: State

    private func setPercent(_ value: Int) {
        percent = max(0, min(100, value))
        defaults.set(percent, forKey: "percent")
        refresh()
    }

    private func setEnergy(_ mode: EnergyMode) {
        energy = mode
        defaults.set(mode.rawValue, forKey: "energy")
        refresh()
    }

    private func refresh() {
        if let button = statusItem.button {
            button.image = batteryImage()
            button.imagePosition = .imageRight
            button.title = showPercent ? "\(percent)%" : ""
        }

        if headerRow != nil {
            headerRow.rightLabel.stringValue = "\(percent)%"
            sourceRow.leftLabel.stringValue = charging ? "Power Source: Power Adapter" : "Power Source: Battery"
            for row in energyRows { row.isSelected = (row.mode == energy) }
        }

        if settingsWindow != nil {
            wSlider.integerValue = percent
            if wField.currentEditor() == nil { wField.integerValue = percent }
            wCharging.state = charging ? .on : .off
            wShow.state = showPercent ? .on : .off
            wSim.state = simulating ? .on : .off
            wWarn.state = warningsEnabled ? .on : .off
            if wMinutes.currentEditor() == nil { wMinutes.doubleValue = minutesPerPercent }
            if wChargeMinutes.currentEditor() == nil { wChargeMinutes.doubleValue = minutesPerChargePercent }
            wLogin.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            wShowIcon.state = showOwnIcon ? .on : .off
            if wFloor.currentEditor() == nil { wFloor.integerValue = floorPercent }
            wDriver.stringValue = driver.isConnected
                ? "Driver: connected (FakeBatteryDriver.kext is feeding macOS)"
                : "Driver: not found, only the menu bar icon is active"
        }

        statusItem.isVisible = showOwnIcon
        driver.push(percent: percent, charging: charging,
                    timeRemaining: timeRemainingMinutes(), floor: floorPercent)
    }

    // MARK: Menu bar icon

    private func batteryImage() -> NSImage {
        let size = NSSize(width: 27, height: 13)
        let level = CGFloat(percent) / 100
        let isCharging = charging
        let pct = percent
        let lowPower = (energy == .low)

        let image = NSImage(size: size, flipped: false) { _ in
            // Body outline
            let body = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 23, height: 12),
                                    xRadius: 3.5, yRadius: 3.5)
            body.lineWidth = 1
            NSColor.labelColor.withAlphaComponent(0.5).setStroke()
            body.stroke()

            // Nub
            let nub = NSBezierPath(roundedRect: NSRect(x: 24.5, y: 4.25, width: 2, height: 4.5),
                                   xRadius: 1, yRadius: 1)
            NSColor.labelColor.withAlphaComponent(0.5).setFill()
            nub.fill()

            // Fill: green when charging, yellow in Low Power, red at 20% or less
            if pct > 0 {
                let fillColor: NSColor
                if isCharging { fillColor = .systemGreen }
                else if lowPower { fillColor = .systemYellow }
                else if pct <= 20 { fillColor = .systemRed }
                else { fillColor = .labelColor }
                let width = max(2, 19 * level)
                let fill = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: width, height: 9),
                                        xRadius: 1.8, yRadius: 1.8)
                fillColor.setFill()
                fill.fill()
            }

            // Lightning bolt with a cut-out halo
            if isCharging {
                let cx: CGFloat = 12, cy: CGFloat = 6.5
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: cx + 1.2, y: cy + 4))
                bolt.line(to: NSPoint(x: cx - 2.8, y: cy - 0.4))
                bolt.line(to: NSPoint(x: cx - 0.2, y: cy - 0.4))
                bolt.line(to: NSPoint(x: cx - 1.2, y: cy - 4))
                bolt.line(to: NSPoint(x: cx + 2.8, y: cy + 0.4))
                bolt.line(to: NSPoint(x: cx + 0.2, y: cy + 0.4))
                bolt.close()

                NSGraphicsContext.current?.compositingOperation = .destinationOut
                bolt.lineWidth = 2.5
                bolt.lineJoinStyle = .round
                NSColor.black.setStroke()
                bolt.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver

                NSColor.labelColor.setFill()
                bolt.fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Settings window

    @objc private func openSettings() {
        if settingsWindow == nil { buildSettingsWindow() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func buildSettingsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Battery Settings"
        window.isReleasedWhenClosed = false

        wSlider = NSSlider(value: Double(percent), minValue: 0, maxValue: 100,
                           target: self, action: #selector(sliderChanged(_:)))
        wSlider.isContinuous = true
        wSlider.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 100
        wField = NSTextField(string: "\(percent)")
        wField.formatter = formatter
        wField.alignment = .right
        wField.target = self
        wField.action = #selector(fieldChanged(_:))
        wField.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let levelRow = NSStackView(views: [NSTextField(labelWithString: "Charge level"),
                                           wSlider, wField, NSTextField(labelWithString: "%")])
        levelRow.orientation = .horizontal
        levelRow.spacing = 8

        wCharging = NSButton(checkboxWithTitle: "Charging (Power Adapter)", target: self, action: #selector(toggleCharging))
        wShow = NSButton(checkboxWithTitle: "Show percentage in menu bar", target: self, action: #selector(toggleShowPercent))
        wSim = NSButton(checkboxWithTitle: "Simulate drain / charge", target: self, action: #selector(toggleSimulate))

        let minFormatter = NumberFormatter()
        minFormatter.numberStyle = .decimal
        minFormatter.allowsFloats = true
        minFormatter.maximumFractionDigits = 1
        minFormatter.minimum = 0.1
        minFormatter.maximum = 1000
        wMinutes = NSTextField(string: minFormatter.string(from: NSNumber(value: minutesPerPercent)) ?? "10")
        wMinutes.formatter = minFormatter
        wMinutes.alignment = .right
        wMinutes.target = self
        wMinutes.action = #selector(minutesChanged(_:))
        wMinutes.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let minutesRow = NSStackView(views: [NSTextField(labelWithString: "Drain 1% every"),
                                             wMinutes, NSTextField(labelWithString: "minutes")])
        minutesRow.orientation = .horizontal
        minutesRow.spacing = 8

        wChargeMinutes = NSTextField(string: minFormatter.string(from: NSNumber(value: minutesPerChargePercent)) ?? "5")
        wChargeMinutes.formatter = minFormatter
        wChargeMinutes.alignment = .right
        wChargeMinutes.target = self
        wChargeMinutes.action = #selector(chargeMinutesChanged(_:))
        wChargeMinutes.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let chargeRow = NSStackView(views: [NSTextField(labelWithString: "Charge 1% every"),
                                            wChargeMinutes, NSTextField(labelWithString: "minutes")])
        chargeRow.orientation = .horizontal
        chargeRow.spacing = 8

        wWarn = NSButton(checkboxWithTitle: "Show low battery warnings (10%, 5%, 1%)", target: self, action: #selector(toggleWarnings))
        wDriver = NSTextField(labelWithString: "Driver: checking...")
        wShowIcon = NSButton(checkboxWithTitle: "Show FakeBattery icon in menu bar", target: self, action: #selector(toggleShowIcon))

        let floorFormatter = NumberFormatter()
        floorFormatter.numberStyle = .none
        floorFormatter.allowsFloats = false
        floorFormatter.minimum = 0
        floorFormatter.maximum = 50
        wFloor = NSTextField(string: "\(floorPercent)")
        wFloor.formatter = floorFormatter
        wFloor.alignment = .right
        wFloor.target = self
        wFloor.action = #selector(floorChanged(_:))
        wFloor.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let floorRow = NSStackView(views: [NSTextField(labelWithString: "Lowest level macOS is shown"),
                                           wFloor, NSTextField(labelWithString: "%")])
        floorRow.orientation = .horizontal
        floorRow.spacing = 8

        wLogin = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(toggleLogin))
        let quitButton = NSButton(title: "Quit FakeBattery", target: self, action: #selector(quit))

        let stack = NSStackView(views: [levelRow, wCharging, wShow, wSim, minutesRow, chargeRow, wWarn, wDriver, wShowIcon, floorRow, wLogin, quitButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)

        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
        settingsWindow = window
    }

    // MARK: Actions

    @objc private func sliderChanged(_ sender: NSSlider) {
        setPercent(sender.integerValue)
    }

    @objc private func fieldChanged(_ sender: NSTextField) {
        setPercent(sender.integerValue)
    }

    @objc private func toggleCharging() {
        charging.toggle()
        defaults.set(charging, forKey: "charging")
        restartTimer()
        refresh()
    }

    @objc private func toggleShowPercent() {
        showPercent.toggle()
        defaults.set(showPercent, forKey: "showPercent")
        refresh()
    }

    @objc private func toggleSimulate() {
        simulating.toggle()
        defaults.set(simulating, forKey: "simulating")
        restartTimer()
        refresh()
    }

    @objc private func minutesChanged(_ sender: NSTextField) {
        minutesPerPercent = max(0.1, min(1000, sender.doubleValue))
        defaults.set(minutesPerPercent, forKey: "minutesPerPercent")
        restartTimer()
        refresh()
    }

    @objc private func chargeMinutesChanged(_ sender: NSTextField) {
        minutesPerChargePercent = max(0.1, min(1000, sender.doubleValue))
        defaults.set(minutesPerChargePercent, forKey: "minutesPerChargePercent")
        restartTimer()
        refresh()
    }

    /// Launching the app again opens Battery Settings, even if the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    /// Minutes shown to macOS as the time remaining (65535 = "no estimate").
    private func timeRemainingMinutes() -> Int {
        guard simulating else { return 0xFFFF }
        let minutes = charging ? Double(100 - percent) * minutesPerChargePercent
                               : Double(percent) * minutesPerPercent
        return min(0xFFFE, Int(minutes.rounded()))
    }

    @objc private func toggleShowIcon() {
        showOwnIcon.toggle()
        defaults.set(showOwnIcon, forKey: "showOwnIcon")
        refresh()
    }

    @objc private func floorChanged(_ sender: NSTextField) {
        floorPercent = max(0, min(50, sender.integerValue))
        defaults.set(floorPercent, forKey: "floorPercent")
        refresh()
    }

    @objc private func toggleWarnings() {
        warningsEnabled.toggle()
        defaults.set(warningsEnabled, forKey: "warnings")
        refresh()
    }

    /// Discharging: -1% every `minutesPerPercent` minutes. Charging: +1% every `minutesPerChargePercent` minutes.
    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard simulating else { return }
        let interval = (charging ? minutesPerChargePercent : minutesPerPercent) * 60.0
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard !showingWarning else { return }   // pause while a warning is on screen
        let previous = percent
        setPercent(percent + (charging ? 1 : -1))
        if !charging, percent < previous, [10, 5, 1].contains(percent) {
            showWarning(percent)
        }
    }

    /// The "shutdown" warning. It is only a pop-up: nothing is ever shut down.
    private func showWarning(_ level: Int) {
        guard warningsEnabled else { return }
        showingWarning = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Low Battery"
        alert.informativeText = "Your battery is at \(level)%. Your Mac will shut down soon. Connect a power adapter to keep working."
        alert.addButton(withTitle: "OK")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show these warnings again"
        alert.runModal()
        if alert.suppressionButton?.state == .on {
            warningsEnabled = false
            defaults.set(false, forKey: "warnings")
        }
        showingWarning = false
        refresh()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

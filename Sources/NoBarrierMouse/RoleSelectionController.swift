import AppKit
import Cocoa

final class RoleSelectionController: NSObject, NSWindowDelegate {
    private var _window: NSWindow?
    private var onSelect: ((AppRole) -> Void)?

    func show(onSelect: @escaping (AppRole) -> Void) {
        self.onSelect = onSelect

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "No Barrier Mouse"
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self

        let contentView = window.contentView!

        let vfx = NSVisualEffectView(frame: contentView.bounds)
        vfx.autoresizingMask = [.width, .height]
        vfx.blendingMode = .withinWindow
        vfx.material = .popover
        vfx.state = .active
        contentView.addSubview(vfx)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 420)
        ])

        let iconView = NSImageView()
        iconView.image = MouseIcon.make()
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = makeLabel("No Barrier Mouse", size: 22, weight: .medium, color: .labelColor)
        let subtitleLabel = makeLabel("Choose your role", size: 13, weight: .regular, color: .secondaryLabelColor)

        stack.addArrangedSubview(iconView)
        stack.setCustomSpacing(6, after: iconView)
        stack.addArrangedSubview(titleLabel)
        stack.setCustomSpacing(2, after: titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.setCustomSpacing(20, after: subtitleLabel)

        let controllerCard = RoleCard(
            icon: ControllerIcon.make(),
            title: "Controller",
            description: "Share your keyboard and mouse\nwith another Mac"
        )
        controllerCard.onClick = { [weak self] in self?.select(.controller) }

        let receiverCard = RoleCard(
            icon: ReceiverIcon.make(),
            title: "Receiver",
            description: "Be controlled by another Mac's\nkeyboard and mouse"
        )
        receiverCard.onClick = { [weak self] in self?.select(.receiver) }

        let cardStack = NSStackView(views: [controllerCard, receiverCard])
        cardStack.orientation = .horizontal
        cardStack.spacing = 14
        cardStack.alignment = .centerY
        cardStack.distribution = .fillEqually

        stack.addArrangedSubview(cardStack)

        self._window = window
        self._window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    deinit {
        print("RoleSelectionController deinit")
    }

    private func select(_ role: AppRole) {
        _window?.delegate = nil
        _window?.close()
        onSelect?(role)
        onSelect = nil
    }

    func windowWillClose(_ notification: Notification) {
        onSelect = nil
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.backgroundColor = .clear
        return label
    }
}

final class RoleCard: NSView {
    var onClick: (() -> Void)?
    private var isHovering = false {
        didSet { updateAppearance() }
    }

    init(icon: NSImage, title: String, description: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10

        updateAppearance()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = icon
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = makeLabel(title, size: 14, weight: .medium, color: .labelColor)
        let descLabel = makeLabel(description, size: 11, weight: .regular, color: .secondaryLabelColor)
        descLabel.alignment = .center

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(descLabel)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            widthAnchor.constraint(equalToConstant: 182),
            heightAnchor.constraint(equalToConstant: 150)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    private func updateAppearance() {
        if isHovering {
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
            layer?.borderWidth = 1.5
            if #available(macOS 10.14, *) {
                layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            }
        } else {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.backgroundColor = .clear
        return label
    }
}

enum ControllerIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 44, height: 28)
        let image = NSImage(size: size)
        image.lockFocus()

        let stroke = NSColor.labelColor
        let fill = NSColor.labelColor.withAlphaComponent(0.18)
        let keyFill = NSColor.labelColor.withAlphaComponent(0.72)

        fill.setFill()
        stroke.setStroke()

        let body = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 4, width: 39, height: 21), xRadius: 4.5, yRadius: 4.5)
        body.fill()
        body.lineWidth = 1.4
        body.stroke()

        let topLip = NSBezierPath()
        topLip.move(to: NSPoint(x: 8, y: 22))
        topLip.line(to: NSPoint(x: 36, y: 22))
        topLip.lineWidth = 1.1
        topLip.lineCapStyle = .round
        topLip.stroke()

        keyFill.setFill()
        drawKeyRow(count: 6, y: 17.1, keyWidth: 3.8, keyHeight: 3.1, gap: 2.0)
        drawKeyRow(count: 6, y: 12.4, keyWidth: 3.8, keyHeight: 3.1, gap: 2.0)
        drawKey(x: 5.9, y: 7.7, width: 4.4)
        drawKey(x: 12.3, y: 7.7, width: 19.4)
        drawKey(x: 33.7, y: 7.7, width: 4.4)

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func drawKeyRow(count: Int, y: CGFloat, keyWidth: CGFloat, keyHeight: CGFloat, gap: CGFloat) {
        let totalWidth = CGFloat(count) * keyWidth + CGFloat(count - 1) * gap
        let startX = (44 - totalWidth) / 2

        for index in 0..<count {
            drawKey(
                x: startX + CGFloat(index) * (keyWidth + gap),
                y: y,
                width: keyWidth,
                height: keyHeight
            )
        }
    }

    private static func drawKey(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 3.1) {
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: 1.1, yRadius: 1.1).fill()
    }
}

enum ReceiverIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 44, height: 28)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.labelColor.setStroke()

        let screen = NSBezierPath(roundedRect: NSRect(x: 4, y: 7, width: 36, height: 19), xRadius: 3, yRadius: 3)
        screen.lineWidth = 1.5
        screen.stroke()

        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 22, y: 7))
        stand.line(to: NSPoint(x: 22, y: 3))
        stand.lineWidth = 2
        stand.stroke()

        let base = NSBezierPath()
        base.move(to: NSPoint(x: 14, y: 3))
        base.line(to: NSPoint(x: 30, y: 3))
        base.lineWidth = 3
        base.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

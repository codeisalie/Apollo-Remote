import AppKit

/// Native macOS menu-bar status icon used by APOLLO REMOTE.
enum ApolloStatusIconStyle: String, CaseIterable {
    case arcColor = "Arc — Color"
    case arcMonochrome = "Arc — Grey"
    case speakerColor = "Speaker — Color"
    case speakerMonochrome = "Speaker — Grey"
}

enum ApolloArcIcon {
    private static let side: CGFloat = 20

    static func image(
        fraction: CGFloat,
        active: Bool,
        muted: Bool = false,
        dimmed: Bool = false,
        mono: Bool = false,
        style: ApolloStatusIconStyle = .arcColor
    ) -> NSImage {
        let value = max(0, min(1, fraction))
        let ink = color(active: active, muted: muted, dimmed: dimmed, mono: mono, style: style)

        switch style {
        case .speakerColor, .speakerMonochrome:
            return speakerImage(ink: ink, active: active, style: style)
        case .arcColor, .arcMonochrome:
            return arcImage(value: value, ink: ink, active: active)
        }
    }

    private static func color(
        active: Bool,
        muted: Bool,
        dimmed: Bool,
        mono: Bool,
        style: ApolloStatusIconStyle
    ) -> NSColor {
        let monochrome = style == .arcMonochrome || style == .speakerMonochrome
        if monochrome {
            return NSColor.secondaryLabelColor
        }
        if !active {
            return NSColor.systemGray
        }
        if muted {
            return NSColor.systemRed
        }
        if dimmed || mono {
            return NSColor.systemOrange
        }
        // The color styles default to green; gray is reserved for the
        // explicit monochrome styles above.
        return NSColor.systemGreen
    }

    private static func arcImage(value: CGFloat, ink: NSColor, active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY - 1.5)
            let radius: CGFloat = 6.5
            let startAngle: CGFloat = 215
            let endAngle: CGFloat = -35
            let lineWidth: CGFloat = 3.2

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius,
                            startAngle: startAngle, endAngle: endAngle, clockwise: true)
            track.lineWidth = lineWidth
            track.lineCapStyle = .round
            ink.withAlphaComponent(active ? 0.25 : 0.16).set()
            track.stroke()

            guard value > 0.001 else { return true }

            let fillEnd = startAngle + (endAngle - startAngle) * value
            let fill = NSBezierPath()
            fill.appendArc(withCenter: center, radius: radius,
                           startAngle: startAngle, endAngle: fillEnd, clockwise: true)
            fill.lineWidth = lineWidth
            fill.lineCapStyle = .round
            ink.set()
            fill.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func speakerImage(ink: NSColor, active: Bool, style: ApolloStatusIconStyle) -> NSImage {
        // Draw the SF Symbol into a fixed 18×18 canvas so it never overflows
        // the menu-bar slot or appears stretched / clipped.
        let canvas = NSSize(width: side, height: side)
        let image = NSImage(size: canvas, flipped: false) { rect in
            let symbolName = "speaker.wave.2.fill"
            // ~11–12 pt fits cleanly inside an 18 pt menu-bar item with padding.
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [ink.withAlphaComponent(active ? 1.0 : 0.55)]))
            guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Apollo Remote"),
                  let configured = symbol.withSymbolConfiguration(config) else {
                return true
            }
            let symbolSize = configured.size
            // Center within the canvas; keep aspect ratio (no stretch).
            let drawRect = NSRect(
                x: (rect.width - symbolSize.width) / 2,
                y: (rect.height - symbolSize.height) / 2,
                width: symbolSize.width,
                height: symbolSize.height
            )
            configured.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        image.isTemplate = false
        return image
    }
}

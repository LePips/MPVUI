/// Converts the bundled mpv extension's copied node snapshot into public Swift
/// values and resolves WebVTT cue settings into physical viewport placement.
enum MPVTextSubtitleParser {
    private static let safeAreaInset: Float = 0.04

    /// Integer WebVTT line positions are based on the rendered first-line box,
    /// which does not exist until the client chooses a font. This estimate keeps
    /// their ordering and edge affinity useful without claiming pixel identity.
    private static let estimatedSnapLineStep: Float = 0.05

    static func snapshot(from node: MPVNodeValue?) -> TextSubtitleSnapshot {
        let regions =
            node?.arrayValue?.compactMap { value -> TextSubtitleRegion? in
                guard let fields = value.mapValue,
                      let text = fields["text"]?.stringValue,
                      !text.isEmpty
                else { return nil }

                let placement: TextSubtitlePlacement =
                    if fields["format"]?.stringValue == "webvtt" {
                        .webVTT(
                            webVTTPlacement(
                                from: fields["settings"]?.stringValue ?? "",
                                cueText: text
                            )
                        )
                    } else {
                        .automatic
                    }

                return TextSubtitleRegion(text: text, placement: placement)
            } ?? []
        return TextSubtitleSnapshot(regions: regions)
    }

    static func webVTTPlacement(
        from rawSettings: String,
        cueText: String = ""
    ) -> WebVTTPlacement {
        let settings = CueSettings(rawValue: rawSettings)
        let writingDirection = writingDirection(for: settings.vertical)
        let baseDirection = cueBaseDirection(cueText)
        let alignment = settings.alignment ?? .center
        let textAlignment = physicalTextAlignment(
            for: alignment,
            baseDirection: baseDirection
        )
        let inlinePosition =
            settings.position?.value
                ?? defaultInlinePosition(for: alignment)
        let inlineAnchor =
            settings.position?.anchor
                ?? defaultPositionAnchor(for: alignment, baseDirection: baseDirection)
        let maximumExtent = settings.size.map {
            min($0, availableInlineExtent(at: inlinePosition, anchor: inlineAnchor))
        }

        switch writingDirection {
        case .horizontal:
            let line = horizontalLinePlacement(settings.line)
            return WebVTTPlacement(
                horizontalPosition: inlinePosition,
                verticalPosition: line.position,
                horizontalAnchor: horizontalInlineAnchor(inlineAnchor),
                verticalAnchor: line.anchor,
                maximumWidth: maximumExtent,
                textAlignment: textAlignment,
                writingDirection: writingDirection
            )

        case .verticalGrowingLeft, .verticalGrowingRight:
            let line = verticalLinePlacement(
                settings.line,
                direction: writingDirection
            )
            return WebVTTPlacement(
                horizontalPosition: line.position,
                verticalPosition: inlinePosition,
                horizontalAnchor: line.anchor,
                verticalAnchor: verticalInlineAnchor(inlineAnchor),
                maximumHeight: maximumExtent,
                textAlignment: textAlignment,
                writingDirection: writingDirection
            )
        }
    }
}

private extension MPVTextSubtitleParser {
    enum CueAlignment {
        case start
        case center
        case end
        case left
        case right

        init?(rawValue: String) {
            switch rawValue {
            case "start": self = .start
            case "center": self = .center
            case "end": self = .end
            case "left": self = .left
            case "right": self = .right
            default: return nil
            }
        }
    }

    enum PositionAnchor {
        case lineLeft
        case center
        case lineRight

        init?(rawValue: String) {
            switch rawValue {
            case "line-left": self = .lineLeft
            case "center": self = .center
            case "line-right": self = .lineRight
            default: return nil
            }
        }
    }

    enum LineAnchor {
        case start
        case center
        case end

        init?(rawValue: String) {
            switch rawValue {
            case "start": self = .start
            case "center": self = .center
            case "end": self = .end
            default: return nil
            }
        }
    }

    enum LineSetting {
        case percentage(Float, anchor: LineAnchor)
        case snap(Float)
    }

    enum BaseDirection {
        case leftToRight
        case rightToLeft
    }

    struct PositionSetting {
        let value: Float
        let anchor: PositionAnchor?
    }

    struct CueSettings {
        var vertical: String?
        var line: LineSetting?
        var position: PositionSetting?
        var size: Float?
        var alignment: CueAlignment?

        init(rawValue: String) {
            for field in rawValue.split(whereSeparator: { $0.isWhitespace }) {
                guard let separator = field.firstIndex(of: ":") else { continue }
                let key = String(field[..<separator])
                let value = String(field[field.index(after: separator)...])
                guard !value.isEmpty else { continue }

                // Invalid values leave the prior value unchanged. A later
                // valid occurrence replaces an earlier one, matching WebVTT's
                // sequential cue-settings parser.
                switch key {
                case "vertical":
                    if value == "rl" || value == "lr" {
                        vertical = value
                    }
                case "line":
                    if let parsed = parseLine(value) {
                        line = parsed
                    }
                case "position":
                    if let parsed = parsePosition(value) {
                        position = parsed
                    }
                case "size":
                    if let parsed = percentage(value) {
                        size = parsed
                    }
                case "align":
                    if let parsed = CueAlignment(rawValue: value) {
                        alignment = parsed
                    }
                default:
                    break
                }
            }
        }
    }

    struct HorizontalLinePlacement {
        let position: Float
        let anchor: WebVTTPlacement.VerticalAnchor
    }

    struct VerticalLinePlacement {
        let position: Float
        let anchor: WebVTTPlacement.HorizontalAnchor
    }

    static func parsePosition(_ value: String) -> PositionSetting? {
        let components = value.split(
            separator: ",",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard let position = percentage(components[0]) else { return nil }

        let anchor: PositionAnchor?
        if components.count == 2 {
            guard let parsedAnchor = PositionAnchor(rawValue: components[1]) else {
                return nil
            }
            anchor = parsedAnchor
        } else {
            anchor = nil
        }
        return PositionSetting(value: position, anchor: anchor)
    }

    static func parseLine(_ value: String) -> LineSetting? {
        let components = value.split(
            separator: ",",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).map(String.init)
        let anchor: LineAnchor
        if components.count == 2 {
            guard let parsedAnchor = LineAnchor(rawValue: components[1]) else {
                return nil
            }
            anchor = parsedAnchor
        } else {
            anchor = .start
        }

        if let position = percentage(components[0]) {
            return .percentage(position, anchor: anchor)
        }
        guard let line = Float(components[0]), line.isFinite else { return nil }
        return .snap(line)
    }

    static func percentage(_ value: String?) -> Float? {
        guard let value,
              value.hasSuffix("%"),
              let result = Float(value.dropLast()),
              result.isFinite,
              (0 ... 100).contains(result)
        else { return nil }
        return result / 100
    }

    static func writingDirection(
        for value: String?
    ) -> WebVTTPlacement.WritingDirection {
        switch value {
        case "rl": .verticalGrowingLeft
        case "lr": .verticalGrowingRight
        default: .horizontal
        }
    }

    static func cueBaseDirection(_ text: String) -> BaseDirection {
        for scalar in text.unicodeScalars {
            if scalar.value == 0x200F {
                return .rightToLeft
            }
            if scalar.value == 0x200E {
                return .leftToRight
            }

            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
                 .modifierLetter, .otherLetter:
                return isRightToLeftLetter(scalar)
                    ? .rightToLeft
                    : .leftToRight
            default:
                continue
            }
        }
        return .leftToRight
    }

    static func isRightToLeftLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590 ... 0x08FF,
             0xFB1D ... 0xFDFF,
             0xFE70 ... 0xFEFF,
             0x10800 ... 0x10FFF,
             0x1E800 ... 0x1EEFF:
            true
        default:
            false
        }
    }

    static func physicalTextAlignment(
        for alignment: CueAlignment,
        baseDirection: BaseDirection
    ) -> WebVTTPlacement.TextAlignment {
        switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        case .start:
            baseDirection == .leftToRight ? .left : .right
        case .end:
            baseDirection == .leftToRight ? .right : .left
        }
    }

    static func defaultInlinePosition(for alignment: CueAlignment) -> Float {
        switch alignment {
        case .left: 0
        case .right: 1
        case .start, .center, .end: 0.5
        }
    }

    static func defaultPositionAnchor(
        for alignment: CueAlignment,
        baseDirection: BaseDirection
    ) -> PositionAnchor {
        switch alignment {
        case .left: .lineLeft
        case .center: .center
        case .right: .lineRight
        case .start:
            baseDirection == .leftToRight ? .lineLeft : .lineRight
        case .end:
            baseDirection == .leftToRight ? .lineRight : .lineLeft
        }
    }

    static func availableInlineExtent(
        at position: Float,
        anchor: PositionAnchor
    ) -> Float {
        switch anchor {
        case .lineLeft:
            max(0, 1 - position)
        case .center:
            max(0, 2 * min(position, 1 - position))
        case .lineRight:
            max(0, position)
        }
    }

    static func horizontalInlineAnchor(
        _ anchor: PositionAnchor
    ) -> WebVTTPlacement.HorizontalAnchor {
        switch anchor {
        case .lineLeft: .left
        case .center: .center
        case .lineRight: .right
        }
    }

    static func verticalInlineAnchor(
        _ anchor: PositionAnchor
    ) -> WebVTTPlacement.VerticalAnchor {
        switch anchor {
        case .lineLeft: .top
        case .center: .center
        case .lineRight: .bottom
        }
    }

    static func horizontalLinePlacement(
        _ setting: LineSetting?
    ) -> HorizontalLinePlacement {
        switch setting {
        case nil:
            return HorizontalLinePlacement(
                position: 1 - safeAreaInset,
                anchor: .bottom
            )
        case let .percentage(position, anchor):
            return HorizontalLinePlacement(
                position: position,
                anchor: verticalLineAnchor(anchor)
            )
        case let .snap(line):
            let roundedLine = (line + 0.5).rounded(.down)
            let position =
                roundedLine < 0
                    ? 1 - safeAreaInset + (roundedLine + 1) * estimatedSnapLineStep
                    : safeAreaInset + roundedLine * estimatedSnapLineStep
            return HorizontalLinePlacement(
                position: position,
                anchor: roundedLine < 0 ? .bottom : .top
            )
        }
    }

    static func verticalLinePlacement(
        _ setting: LineSetting?,
        direction: WebVTTPlacement.WritingDirection
    ) -> VerticalLinePlacement {
        let growsLeft = direction == .verticalGrowingLeft
        switch setting {
        case nil:
            return VerticalLinePlacement(
                position: growsLeft ? 1 - safeAreaInset : safeAreaInset,
                anchor: growsLeft ? .right : .left
            )
        case let .percentage(position, anchor):
            return VerticalLinePlacement(
                position: position,
                anchor: horizontalLineAnchor(anchor, growsLeft: growsLeft)
            )
        case let .snap(line):
            let roundedLine = (line + 0.5).rounded(.down)
            let fromHighEdge = growsLeft ? roundedLine >= 0 : roundedLine < 0
            let distance = roundedLine >= 0 ? roundedLine : -roundedLine - 1
            return VerticalLinePlacement(
                position: fromHighEdge
                    ? 1 - safeAreaInset - distance * estimatedSnapLineStep
                    : safeAreaInset + distance * estimatedSnapLineStep,
                anchor: fromHighEdge ? .right : .left
            )
        }
    }

    static func verticalLineAnchor(
        _ anchor: LineAnchor
    ) -> WebVTTPlacement.VerticalAnchor {
        switch anchor {
        case .start: .top
        case .center: .center
        case .end: .bottom
        }
    }

    static func horizontalLineAnchor(
        _ anchor: LineAnchor,
        growsLeft: Bool
    ) -> WebVTTPlacement.HorizontalAnchor {
        switch anchor {
        case .start: growsLeft ? .right : .left
        case .center: .center
        case .end: growsLeft ? .left : .right
        }
    }
}

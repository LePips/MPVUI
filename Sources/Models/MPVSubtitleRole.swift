/// One of mpv's two simultaneous subtitle selections.
public enum MPVSubtitleRole: String, CaseIterable, Hashable, Sendable {
    /// The primary subtitle selection.
    case primary
    /// The secondary subtitle selection.
    case secondary

    var selectionProperty: String {
        self == .primary ? "sid" : "secondary-sid"
    }

    var delayProperty: String {
        self == .primary ? "sub-delay" : "secondary-sub-delay"
    }

    var visibilityProperty: String {
        self == .primary ? "sub-visibility" : "secondary-sub-visibility"
    }

    var other: Self {
        self == .primary ? .secondary : .primary
    }
}

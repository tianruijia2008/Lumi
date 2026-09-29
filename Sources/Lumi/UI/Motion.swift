import SwiftUI

/// One place for every animation curve in the app.
///
/// Consistency is what reads as "smooth": if the panel, the cards and the
/// language pills all settle with the same physics, the UI feels like one
/// object rather than several widgets that happen to share a window.
enum Motion {
    /// Default for layout changes — no overshoot, so text never jitters.
    static let settle = Animation.smooth(duration: 0.34)
    /// Elements entering or leaving; a little bounce sells the glass.
    static let pop = Animation.spring(response: 0.38, dampingFraction: 0.74)
    /// Fast feedback for taps and hovers.
    static let tap = Animation.spring(response: 0.22, dampingFraction: 0.8)
    /// Streaming text: slow enough to read, fast enough not to lag the tokens.
    static let stream = Animation.easeOut(duration: 0.18)
}

extension AnyTransition {
    /// Switching services in the rail. A crossfade with a small vertical
    /// nudge: enough to register as a change, not enough to make the reader
    /// chase the text.
    static var bodySwap: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 5)),
            removal: .opacity
        )
    }
}

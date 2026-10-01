import SwiftUI

/// The chrome vocabulary both windows are built from.
///
/// The panel and the 工作台 are very different surfaces — one is an overlay you
/// read for four seconds, the other a document you keep open for an hour — and
/// what makes them one app is not a shared layout but a shared set of small
/// parts: the capsule that means *a choice*, the 22pt square that means *an
/// action*, the one type size chrome is set in. Copying those values into a
/// second file is how they drift, so they live here and both windows use them.
enum Chrome {
    /// Every label in the chrome. Rounded, because it has to read at 11pt.
    static let chipFont = Font.system(size: 11, weight: .medium, design: .rounded)
    static let chipStroke = Color.secondary.opacity(0.22)
    static let activeStroke = Color.accentColor.opacity(0.55)
    static let activeFill = Color.accentColor.opacity(0.18)
    /// Hairlines *inside* a document. `Divider` is tuned to separate panes and
    /// is far too dark to repeat sixty times down a page.
    static let rule = Color.primary.opacity(0.07)
    /// The row under the pointer. Barely there on purpose: it says "this row",
    /// not "this row is selected".
    static let hover = Color.primary.opacity(0.035)
}

extension View {
    /// The capsule outline that marks a choice: the panel's language pair, the
    /// service rail's chips, the workbench's engine switch.
    func chipShell(active: Bool = false) -> some View {
        background { Capsule().fill(active ? Chrome.activeFill : .clear) }
            .overlay {
                Capsule().strokeBorder(
                    active ? Chrome.activeStroke : Chrome.chipStroke, lineWidth: 1
                )
            }
    }
}

/// A 22pt square that does one thing.
///
/// The hit area is the square, not the glyph: an 11pt symbol is a 5pt target
/// once you account for where the ink actually is.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var size: CGFloat = 11
    var active: Bool = false
    /// Overrides the accent/secondary pair — for the one case where the button
    /// belongs to a warning and has to be read as part of it.
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(resolved)
        .help(help)
    }

    private var resolved: AnyShapeStyle {
        if let tint { AnyShapeStyle(tint) }
        else if active { AnyShapeStyle(Color.accentColor) }
        else { AnyShapeStyle(.secondary) }
    }
}

/// Two halves in one capsule, the selected one sliding between them.
///
/// The choice between the on-device engine and a language model is *what kind
/// of result this is*, not a setting among others, so it is drawn as two
/// visible alternatives rather than a menu. Shared by the reader and the 词源
/// page, which make the same choice about different work.
struct EngineToggle: View {
    @Binding var selection: WorkbenchEngineID
    var onlineName = t("联网")
    var onlineSymbol = "cloud"
    /// The same orange dot the service rail uses for "on but not set up".
    var onlineUnconfigured = false
    var disabled = false
    var help: (WorkbenchEngineID) -> String = { _ in "" }

    @Namespace private var slider

    var body: some View {
        HStack(spacing: 2) {
            // Not `allCases`: the order is a progression — what always works,
            // then what is better when it can be — and must not change because
            // someone reorders the enum.
            ForEach([WorkbenchEngineID.offline, .online]) { half($0) }
        }
        .padding(2)
        .chipShell()
        .opacity(disabled ? 0.45 : 1)
        .allowsHitTesting(!disabled)
        .animation(Motion.tap, value: selection)
        .animation(Motion.tap, value: disabled)
    }

    private func half(_ id: WorkbenchEngineID) -> some View {
        let selected = id == selection
        return Button { selection = id } label: {
            HStack(spacing: 4) {
                Image(systemName: id == .offline ? "desktopcomputer" : onlineSymbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(id == .offline ? t("本机") : onlineName)
                    .font(Chrome.chipFont)
                if id == .online, onlineUnconfigured {
                    Circle().fill(.orange).frame(width: 4, height: 4)
                }
            }
            .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                if selected {
                    Capsule().fill(Chrome.activeFill)
                        .matchedGeometryEffect(id: "engineSlider", in: slider)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(help(id))
    }
}

/// Where a page begins: the paper under the chrome's glass.
///
/// Slightly translucent, so the window still reads as one sheet of glass with
/// a page laid on it rather than a hole cut through to an opaque view.
enum Paper {
    static let fill = Color(nsColor: .textBackgroundColor).opacity(0.86)
}

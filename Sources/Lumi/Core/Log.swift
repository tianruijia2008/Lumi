import os

/// Lumi's own log lines, readable with
/// `log show --last 5m --predicate 'subsystem == "com.tianruijia.Lumi"'`.
///
/// A hot-key path crosses four independent failure points — registration,
/// Carbon dispatch, the Accessibility grant, and the selection grab — and each
/// one fails silently. Without a trail, "the shortcut does nothing" can't be
/// told apart from "the shortcut fired and found no text".
enum Log {
    static let hotKey = Logger(subsystem: "com.tianruijia.Lumi", category: "hotkey")
    static let grab   = Logger(subsystem: "com.tianruijia.Lumi", category: "grab")
    /// The workbench window's activation-policy dance, which fails in ways
    /// that look identical to the shortcut not firing.
    static let window = Logger(subsystem: "com.tianruijia.Lumi", category: "window")
}

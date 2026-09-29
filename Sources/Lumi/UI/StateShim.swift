import SwiftUI

/// `@State` is an attached macro in the current SDK, and its implementation
/// (`SwiftUIMacros`) ships only inside Xcode — a Command Line Tools install
/// cannot expand it. The underlying `@propertyWrapper struct State` is still
/// there, though, and a macro is never a candidate in *type* position, so this
/// typealias binds straight to the wrapper.
///
/// `@Stored` behaves exactly like `@State`: same storage, same `$projection`,
/// same `nonmutating set`. If this project ever moves to a full Xcode install,
/// a find-and-replace back to `@State` is the only change needed.
typealias Stored<Value> = SwiftUI.State<Value>

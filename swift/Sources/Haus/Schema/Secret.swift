/// A value that must not end up in logs, such as an API key or a password:
/// the host type of a `Secret a` (spec §15). It hides the value wherever it
/// is shown (`print`, string interpolation, `dump`, debuggers) as
/// `<redacted>`, and gives it out only through ``reveal()``.
///
/// ```swift
/// let key = Secret("sk-live-123")
/// print(key)      // <redacted>
/// key.reveal()    // "sk-live-123"
/// ```
///
/// It protects against accidental exposure in a program, not against anyone
/// who sees the data: the data holds the value in full.
public struct Secret<Wrapped>: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: Wrapped

    public init(_ value: Wrapped) { self.value = value }

    /// The value, given out explicitly.
    public func reveal() -> Wrapped { value }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "Secret(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

extension Secret: Sendable where Wrapped: Sendable {}
extension Secret: Equatable where Wrapped: Equatable {}
extension Secret: Hashable where Wrapped: Hashable {}

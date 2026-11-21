/// Checks that a value built in code can be written within the limits
/// (spec §7, §11), as every writer of values does: numbers (length and
/// exponent), strings, keys, tags and byte strings are within their limits;
/// nesting is within the depth limit (a record payload, `Tag { … }`,
/// counting one level, and an empty record, array or payload a level, as
/// when parsing); and writing it takes at most ``Limits/maxNodes`` values
/// (`too-many-nodes`). The error's ``HausError/path`` says where the problem
/// is, such as `$.items[2]`. Values that ``parse(_:limits:)`` returns pass
/// with the limits they were parsed with.
///
/// Swift's values can't contain themselves, but arrays share their storage:
/// a value built by nesting one array twice in another, again and again, has
/// few arrays and very many nodes, which the node limit bounds.
public func checkValue(_ value: HausValue, limits: Limits = Limits()) throws(HausError) {
    var walk = Walk(NoSpelling(), checks: .writer(try limits.checked()))
    var nothing: [UInt8] = []
    try walk.write(value, to: &nothing)
}

/// The number of characters (code points) of `s` if there are more than
/// `limit`, nil otherwise. Counting is skipped when the UTF-8 is short enough.
func longerThan(_ s: String, _ limit: Int) -> Int? {
    guard s.utf8.count > limit else { return nil }
    let n = s.unicodeScalars.count
    return n > limit ? n : nil
}

/// The error of a normalized number literal over the number limits (spec
/// §7): its code and message, or nil.
func numberLimitError(_ literal: String, _ limits: Limits) -> (HausError.Code, String)? {
    let text = literal.utf8
    if text.count > limits.maxNumberLength {
        return (
            .numberTooLong, "a number of \(text.count) characters, more than the limit of \(limits.maxNumberLength)"
        )
    }
    guard let e = text.firstIndex(of: ASCII.e) else { return nil }
    let exponent = text[text.index(after: e)...].drop { $0 == ASCII.minus }
    guard exponent.count <= 9, exponent.reduce(0, { $0 * 10 + Int($1 - ASCII.zero) }) <= limits.maxExponent else {
        return (.exponentTooLarge, "an exponent larger than the limit of \(limits.maxExponent)")
    }
    return nil
}

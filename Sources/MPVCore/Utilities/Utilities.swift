/// Returns `value` constrained to the supplied closed range.
@inlinable
public func clamped<Value: Comparable>(
    _ value: Value,
    to range: ClosedRange<Value>
) -> Value {
    if value < range.lowerBound {
        return range.lowerBound
    }

    if value > range.upperBound {
        return range.upperBound
    }

    return value
}

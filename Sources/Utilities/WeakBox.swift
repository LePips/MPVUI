/// Holds a non-owning reference to an object.
final class WeakBox<Value: AnyObject> {
    private(set) weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

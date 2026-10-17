/// Holds a non-owning reference to an object.
package final class WeakBox<Value: AnyObject> {

    package private(set) weak var value: Value?

    package init(_ value: Value) {
        self.value = value
    }
}

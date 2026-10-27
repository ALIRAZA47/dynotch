import SwiftUI

/// `@State` for this package. In the macOS 27 SDK `@State` is a macro whose plugin ships
/// only with Xcode, so a Command Line Tools build can't expand it. This wraps the same
/// `State` storage as a plain property wrapper, which builds with either toolchain.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private let storage: SwiftUI.State<Value>

    init(wrappedValue: Value) {
        storage = SwiftUI.State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}

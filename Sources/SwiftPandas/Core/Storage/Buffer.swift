/// Reference-counted contiguous storage buffer with copy-on-write semantics.
///
/// This is the low-level backing store for NativeArray. It wraps a
/// ContiguousArray and uses `isKnownUniquelyReferenced` for efficient CoW.
internal final class ArrayBuffer<T>: @unchecked Sendable {
    var storage: ContiguousArray<T>

    init(_ storage: ContiguousArray<T>) {
        self.storage = storage
    }

    init(repeating value: T, count: Int) {
        self.storage = ContiguousArray(repeating: value, count: count)
    }

    var count: Int { storage.count }
}

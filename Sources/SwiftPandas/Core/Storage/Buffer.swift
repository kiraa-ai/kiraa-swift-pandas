// ============================================================================
// Buffer.swift — Reference-Counted Copy-on-Write Storage Buffer
// ============================================================================
//
// This file provides `ArrayBuffer<T>`, the low-level, heap-allocated backing
// store for `NativeArray`. By wrapping a `ContiguousArray<T>` inside a
// reference type (`final class`), we enable **copy-on-write (CoW)** semantics:
//
// 1. When a `NativeArray` is copied (e.g., assigned to another variable or
//    passed to a function), only the reference to the `ArrayBuffer` is copied
//    — the underlying data is shared.
// 2. Before any mutation, `NativeArray` checks
//    `isKnownUniquelyReferenced(&buffer)`. If the buffer has a single owner,
//    it mutates in place (zero-copy). If the buffer is shared, it first
//    creates a deep copy of the storage, then mutates the copy.
//
// This pattern is the same strategy used by Swift's standard library for
// `Array`, `Data`, and other value types that need O(1) copies and amortized
// O(1) mutations.
//
// ## Thread Safety
//
// `ArrayBuffer` is marked `@unchecked Sendable` because, once created, its
// storage is only mutated through the CoW mechanism described above, which
// guarantees exclusive access at the point of mutation. The `@unchecked`
// annotation is necessary because the compiler cannot statically verify this
// invariant.
//
// ============================================================================

/// A reference-counted, contiguous storage buffer with copy-on-write semantics.
///
/// `ArrayBuffer` is the single heap allocation backing a ``NativeArray``. It
/// wraps a `ContiguousArray<T>` (which guarantees a flat, C-compatible memory
/// layout with no bridging overhead) and exposes just enough API for
/// `NativeArray` to read and mutate the storage efficiently.
///
/// This type is `internal` — it is an implementation detail of the storage
/// layer and should never be used directly by library consumers.
///
/// - Note: Marked `@unchecked Sendable` because mutations are guarded by the
///   CoW uniqueness check in `NativeArray`, ensuring exclusive access.
internal final class ArrayBuffer<T>: @unchecked Sendable {
    /// The underlying contiguous storage holding all elements.
    ///
    /// `ContiguousArray` is preferred over `Array` because it guarantees that
    /// elements are stored in a single, contiguous block of memory with no
    /// Objective-C bridging. This is critical for performance — it enables
    /// pointer-based bulk operations, SIMD/Accelerate integration, and
    /// predictable cache behavior.
    var storage: ContiguousArray<T>

    /// Creates a buffer by adopting an existing `ContiguousArray`.
    ///
    /// The array is moved into the buffer without copying. This is the primary
    /// initializer used when constructing a `NativeArray` from an array literal
    /// or an already-allocated contiguous array.
    ///
    /// - Parameter storage: The contiguous array to wrap. Ownership is
    ///   transferred to the buffer.
    init(_ storage: ContiguousArray<T>) {
        self.storage = storage
    }

    /// Creates a buffer filled with `count` copies of `value`.
    ///
    /// This initializer is used when creating default-filled arrays (e.g., an
    /// all-zeros numeric column or an all-`false` boolean column).
    ///
    /// - Parameters:
    ///   - value: The value to repeat in every element position.
    ///   - count: The number of elements. Must be non-negative.
    init(repeating value: T, count: Int) {
        self.storage = ContiguousArray(repeating: value, count: count)
    }

    /// The number of elements in the buffer.
    ///
    /// Equivalent to `storage.count`. This is an O(1) operation.
    var count: Int { storage.count }
}

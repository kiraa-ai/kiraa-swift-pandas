import Foundation

extension DataFrame {
    /// Approximate in-memory footprint of this DataFrame, in bytes.
    ///
    /// This is the value hot-cache budget accounting uses (``FrameCache``
    /// sizes entries with it), so its accuracy directly bounds how honestly
    /// a cache budget reflects real memory.
    ///
    /// ## Estimation model
    /// - **Numeric/bool columns** — element count × element stride for the
    ///   data buffer, plus the validity bitmap's words (exact for
    ///   ``NullableArray`` storage).
    /// - **String columns** — 16 bytes per `[String?]` slot, plus, for each
    ///   string whose UTF-8 length exceeds 15 (Swift's small-string inline
    ///   capacity), the UTF-8 payload plus a 32-byte heap-buffer header.
    /// - **Names & index** — UTF-8 length of each column name; UTF-8 length
    ///   of each materialized index label (a default range index costs 0).
    ///
    /// The result is an estimate, not an exact measure: it excludes ARC
    /// metadata, allocator bucket rounding, and any retained slices held
    /// outside this value. It is specified to land within ±20% of measured
    /// allocations for representative string/double/int frames
    /// (`EstimatedBytesTests` asserts this bound).
    public var estimatedBytes: Int {
        var total = 0
        for name in columnNames {
            if let col = columns[name] {
                total += col.nbytes
            }
            total += name.utf8.count
        }
        if !_isDefaultIndex {
            for label in _indexLabels {
                total += label.utf8.count
            }
        }
        return total
    }
}

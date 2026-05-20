import Foundation

extension DataFrame {
    /// Approximate in-memory footprint of this DataFrame, in bytes.
    ///
    /// Sums the byte usage of every column's underlying storage (data buffer +
    /// validity bitmap, via ``Column.nbytes``) plus a small per-DataFrame
    /// overhead for column-name strings and the index labels.
    ///
    /// The result is an estimate, not an exact measure: it excludes per-object
    /// Swift overhead (vtable, refcount headers) and any retained slices held
    /// outside this value. It is intended for budgeting and reporting in the
    /// resident-memory server, not for memory safety guarantees.
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

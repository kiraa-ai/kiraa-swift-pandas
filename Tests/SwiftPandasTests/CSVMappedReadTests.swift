import XCTest
@testable import SwiftPandas

/// Tests for Phase A of the CSV-loader memory work: `DataFrame.readCSV(path:)`
/// now reads via `Data(contentsOf:options:.mappedIfSafe)` and walks the bytes
/// directly, skipping the UTF-16 Swift `String` allocation that previously
/// doubled peak memory.
///
/// These tests pin down the **observable** correctness contract:
///   - File-path and url-based reads produce the same DataFrame as the
///     in-memory string read for normal UTF-8 input.
///   - Empty files return an empty DataFrame instead of crashing.
///   - A multi-megabyte file (large enough to trigger the mmap path on
///     `Data(contentsOf:options:.mappedIfSafe)`) loads correctly.
final class CSVMappedReadTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("sp-csvmap-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    private func write(_ csv: String, as name: String = "in.csv") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Round-trip equivalence (path == string)

    func test_pathRead_matchesStringRead_smallFile() throws {
        let csv = """
        region,quarter,revenue,active
        APAC,Q1,15000,true
        EMEA,Q2,22000,false
        US,Q1,35000,true
        """
        let url = try write(csv)

        let fromString = try DataFrame.readCSV(csv)
        let fromPath   = try DataFrame.readCSV(path: url.path)

        XCTAssertEqual(fromPath.rowCount,    fromString.rowCount)
        XCTAssertEqual(fromPath.columnCount, fromString.columnCount)
        XCTAssertEqual(fromPath.columnNames, fromString.columnNames)
        XCTAssertEqual(fromPath.toCSV(),     fromString.toCSV())
    }

    func test_urlRead_matchesPathRead() throws {
        let csv = "a,b\n1,2\n3,4\n"
        let url = try write(csv)

        let fromPath = try DataFrame.readCSV(path: url.path)
        let fromURL  = try DataFrame.readCSV(url: url)

        XCTAssertEqual(fromPath.toCSV(), fromURL.toCSV())
    }

    // MARK: - Empty file

    func test_emptyFile_returnsEmptyDataFrame() throws {
        let url = try write("", as: "empty.csv")
        let df = try DataFrame.readCSV(path: url.path)
        XCTAssertEqual(df.rowCount, 0)
        XCTAssertEqual(df.columnCount, 0)
    }

    func test_headerOnlyFile_returnsZeroRowDataFrame() throws {
        let url = try write("a,b,c\n", as: "header-only.csv")
        let df = try DataFrame.readCSV(path: url.path)
        XCTAssertEqual(df.rowCount, 0)
        XCTAssertEqual(df.columnCount, 3)
        XCTAssertEqual(df.columnNames, ["a", "b", "c"])
    }

    // MARK: - Multi-megabyte file (exercises the mmap path)

    func test_largeFile_loadsCorrectly() throws {
        // ~3 MB synthetic CSV. `Data(contentsOf:options:.mappedIfSafe)` will
        // memory-map a file this size on a local volume rather than copying.
        let rowCount = 60_000
        var csv = "id,region,revenue,units\n"
        csv.reserveCapacity(rowCount * 30)
        for i in 0..<rowCount {
            let region = ["NA", "EMEA", "APAC", "LATAM"][i % 4]
            csv += "\(i),\(region),\(Double(i) * 1.5),\(i % 100)\n"
        }
        let url = try write(csv, as: "big.csv")

        let df = try DataFrame.readCSV(path: url.path)
        XCTAssertEqual(df.rowCount, rowCount)
        XCTAssertEqual(df.columnCount, 4)
        XCTAssertEqual(df.columnNames, ["id", "region", "revenue", "units"])

        // Spot-check a value to confirm parsing actually reached the end.
        let last = df.iloc(rowCount - 1)
        XCTAssertEqual(last["id"] as? Double, Double(rowCount - 1))
        XCTAssertEqual(last["region"] as? String, "LATAM")
    }

    // MARK: - File-not-found surface

    func test_missingFile_throwsFromDataInit() {
        let absent = tmpDir.appendingPathComponent("nope.csv").path
        XCTAssertThrowsError(try DataFrame.readCSV(path: absent))
    }
}

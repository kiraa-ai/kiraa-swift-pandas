import XCTest
@testable import SwiftPandas

// ===----------------------------------------------------------------------===//
// Tests for CSVReader.readValidated(from:): the strict read that owns its own
// contract. It returns a frame only when every declared cell parsed, and
// otherwise throws CSVContractError carrying the per-column report.
// ===----------------------------------------------------------------------===//

final class CSVReaderValidatedTests: XCTestCase {

    /// A blank cell in a declared column is NA by contract, so it must never
    /// be reported as a failure and the read must return the frame.
    func test_readValidated_withBlankDeclaredCell_returnsFrameWithAllRows() throws {
        // Given: a float64 contract on `value` and one blank `value` cell
        let reader = CSVReader.strict(columnTypes: ["value": .float64])
        let csvWithBlankCell = "id,value\nA001,1.5\nA002,\n"

        // When: the text is read under the contract
        let frame = try reader.readValidated(from: csvWithBlankCell)

        // Then: both rows are present; the blank cell did not fail the contract
        XCTAssertEqual(frame.rowCount, 2,
                       "readValidated — case 'blank declared cell': want 2 rows, got \(frame.rowCount)")
    }

    /// A declared cell that fails its dtype parse must throw, and the error
    /// must identify the column and the first offending cell.
    func test_readValidated_withCorruptDeclaredCell_throwsContractErrorNamingTheCell() {
        // Given: a float64 contract on `value` and one unparsable `value` cell
        let reader = CSVReader.strict(columnTypes: ["value": .float64])
        let csvWithCorruptCell = "id,value\nA001,1.5\nA002,1.5x\n"

        // When: the text is read under the contract
        // Then: the read throws CSVContractError naming `value` / `1.5x`
        XCTAssertThrowsError(try reader.readValidated(from: csvWithCorruptCell),
                             "readValidated — case 'corrupt declared cell': want CSVContractError, got a frame") { thrownError in
            guard let contractError = thrownError as? CSVContractError else {
                return XCTFail("readValidated — case 'corrupt declared cell': want CSVContractError, got \(thrownError)")
            }
            guard contractError.failures.count == 1, let failure = contractError.failures.first else {
                return XCTFail("readValidated — case 'corrupt declared cell': want 1 failing column, got \(contractError.failures)")
            }
            XCTAssertEqual(failure.column, "value",
                           "readValidated — case 'corrupt declared cell': want column 'value', got '\(failure.column)'")
            XCTAssertEqual(failure.firstFailedValue, "1.5x",
                           "readValidated — case 'corrupt declared cell': want first failed cell '1.5x', got '\(failure.firstFailedValue)'")
        }
    }

    /// The error's message must name every failing column and its first
    /// offending cell, so a logged error is enough to locate all the damage.
    func test_readValidated_withTwoCorruptColumns_errorDescriptionNamesBoth() {
        // Given: two declared columns, each with one unparsable cell
        let reader = CSVReader.strict(columnTypes: ["lat": .float64, "count": .int64])
        let csvWithTwoCorruptColumns = "id,lat,count\nA001,abc,7\nA002,1.5,seven\n"

        // When: the text is read under the contract
        // Then: the message names both columns and both offending cells
        XCTAssertThrowsError(try reader.readValidated(from: csvWithTwoCorruptColumns),
                             "readValidated — case 'two corrupt columns': want CSVContractError, got a frame") { thrownError in
            guard let contractError = thrownError as? CSVContractError else {
                return XCTFail("readValidated — case 'two corrupt columns': want CSVContractError, got \(thrownError)")
            }
            let message = contractError.errorDescription ?? ""
            for expectedFragment in ["lat", "abc", "count", "seven"] {
                XCTAssertTrue(message.contains(expectedFragment),
                              "readValidated — case 'two corrupt columns': want message to mention '\(expectedFragment)', got '\(message)'")
            }
        }
    }

    /// With no contract there is nothing to violate, so a cell that would
    /// fail a float contract must still come back as a frame, never an error.
    func test_readValidated_withoutContract_returnsFrameForUnparsableCell() throws {
        // Given: an inferring reader and a cell no numeric dtype could parse
        let reader = CSVReader()
        let csvWithUnparsableCell = "id,value\nA001,1.5x\n"

        // When: the text is read with no contract
        let frame = try reader.readValidated(from: csvWithUnparsableCell)

        // Then: the row is present; nothing was reported as a failure
        XCTAssertEqual(frame.rowCount, 1,
                       "readValidated — case 'no contract': want 1 row, got \(frame.rowCount)")
    }
}

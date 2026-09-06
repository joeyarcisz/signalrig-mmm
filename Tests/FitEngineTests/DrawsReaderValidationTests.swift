import XCTest
@testable import FitEngine

final class DrawsReaderValidationTests: XCTestCase {
    private func rows(offset: Double = 0) -> [[String]] {
        DrawsReaderTests.syntheticChainCSV(offset: offset).split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    private func csv(_ rows: [[String]]) -> String {
        rows.map { $0.joined(separator: ",") }.joined(separator: "\n")
    }

    private func withFiles(_ texts: [String], _ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DrawsValidation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (index, text) in texts.enumerated() {
            try text.write(to: dir.appendingPathComponent("mmm_\(index + 1).csv"), atomically: true, encoding: .utf8)
        }
        try body(dir)
    }

    private func dropping(_ name: String, from rows: [[String]]) -> [[String]] {
        let index = rows[0].firstIndex(of: name)!
        return rows.map { row in
            var result = row
            result.remove(at: index)
            return result
        }
    }

    func testBlankMalformedAndNonfinitePosteriorCellsAreRejected() throws {
        for badValue in ["", "not-a-number", "nan", "inf", "-inf", "1e999"] {
            var input = rows()
            let column = input[0].firstIndex(of: "sigma")!
            input[1][column] = badValue
            try withFiles([csv(input)]) { dir in
                XCTAssertThrowsError(try DrawsReader.readChain(path: dir.appendingPathComponent("mmm_1.csv").path)) { error in
                    guard let error = error as? DrawsReaderError,
                          case .invalidValue(_, let line, let name) = error else {
                        return XCTFail("expected invalidValue for \(badValue), got \(error)")
                    }
                    XCTAssertEqual(line, 2)
                    XCTAssertEqual(name, "sigma")
                }
            }
        }
    }

    func testShortAndLongRowsAreRejected() throws {
        for extraField in [false, true] {
            var input = rows()
            if extraField { input[1].append("1") } else { input[1].removeLast() }
            try withFiles([csv(input)]) { dir in
                XCTAssertThrowsError(try DrawsReader.readDirectory(dir: dir.path)) { error in
                    guard let error = error as? DrawsReaderError, case .wrongFieldCount = error else {
                        return XCTFail("expected wrongFieldCount, got \(error)")
                    }
                }
            }
        }
    }

    func testEmptyAndDuplicateHeaderNamesAreRejected() throws {
        for name in ["", "sigma"] {
            var input = rows()
            input[0][0] = name
            try withFiles([csv(input)]) { dir in
                XCTAssertThrowsError(try DrawsReader.readDirectory(dir: dir.path)) { error in
                    guard let error = error as? DrawsReaderError, case .malformedHeader = error else {
                        return XCTFail("expected malformedHeader, got \(error)")
                    }
                }
            }
        }
    }

    func testHeaderWithoutDrawsIsRejected() throws {
        try withFiles([csv([rows()[0]])]) { dir in
            XCTAssertThrowsError(try DrawsReader.readDirectory(dir: dir.path)) { error in
                guard let error = error as? DrawsReaderError, case .noDraws = error else {
                    return XCTFail("expected noDraws, got \(error)")
                }
            }
        }
    }

    func testMissingRequiredScalarAndParameterColumnsAreRejected() throws {
        for missing in ["intercept", "sigma", "divergent__", "hill_kappa.2", "channel_beta.1", "mu_scaled.2"] {
            try withFiles([csv(dropping(missing, from: rows()))]) { dir in
                XCTAssertThrowsError(try DrawsReader.readDirectory(dir: dir.path)) { error in
                    guard let error = error as? DrawsReaderError, case .invalidSchema = error else {
                        return XCTFail("expected invalidSchema for missing \(missing), got \(error)")
                    }
                }
            }
        }
    }

    func testChainHeadersMustMatch() throws {
        let first = rows()
        var second = first
        for row in second.indices { second[row].swapAt(0, 1) }
        try withFiles([csv(first), csv(second)]) { dir in
            XCTAssertThrowsError(try DrawsReader.readDirectory(dir: dir.path)) { error in
                guard let error = error as? DrawsReaderError, case .inconsistentHeaders = error else {
                    return XCTFail("expected inconsistentHeaders, got \(error)")
                }
            }
        }
    }

    func testTruncatedChainDrawCountIsRejected() throws {
        let first = rows()
        try withFiles([csv(first), csv(Array(first.dropLast()))]) { dir in
            XCTAssertThrowsError(try DrawsReader.readDirectory(dir: dir.path)) { error in
                guard let error = error as? DrawsReaderError,
                      case .inconsistentDrawCounts(_, let expected, let actual) = error else {
                    return XCTFail("expected inconsistentDrawCounts, got \(error)")
                }
                XCTAssertEqual(expected, 3)
                XCTAssertEqual(actual, 2)
            }
        }
    }

    func testInconsistentOrNoncontiguousVectorDimensionsAreRejected() throws {
        for (old, new) in [("hill_kappa.2", "hill_kappa.3"), ("control_gamma.1", "control_gamma.2"), ("adstock_alpha.1", "adstock_alpha.0")] {
            var input = rows()
            input[0][input[0].firstIndex(of: old)!] = new
            try withFiles([csv(input)]) { dir in
                XCTAssertThrowsError(try DrawsReader.readDirectory(dir: dir.path))
            }
        }
    }

    func testMediaAndPredictionWeekDimensionsMustMatch() throws {
        let input = dropping("media_scaled.3", from: rows())
        try withFiles([csv(input)]) { dir in
            XCTAssertThrowsError(try DrawsReader.readDirectory(dir: dir.path)) { error in
                guard let error = error as? DrawsReaderError, case .invalidSchema = error else {
                    return XCTFail("expected invalidSchema, got \(error)")
                }
            }
        }
    }

    func testNonModelCSVIsRejected() throws {
        try withFiles(["sigma,divergent__\n0.1,0"]) { dir in
            XCTAssertThrowsError(try DrawsReader.readDirectory(dir: dir.path))
        }
    }

    func testDivergenceIndicatorMustBeBinary() throws {
        for flag in ["-1", "0.5", "2"] {
            var input = rows()
            input[1][input[0].firstIndex(of: "divergent__")!] = flag
            try withFiles([csv(input)]) { dir in
                XCTAssertThrowsError(try DrawsReader.readDirectory(dir: dir.path))
            }
        }
    }

    func testInvalidUTF8IsRejected() throws {
        try withFiles(["placeholder"]) { dir in
            let url = dir.appendingPathComponent("mmm_1.csv")
            try Data([0xff, 0xfe, 0xfd]).write(to: url)
            XCTAssertThrowsError(try DrawsReader.readChain(path: url.path)) { error in
                guard let error = error as? DrawsReaderError, case .invalidUTF8 = error else {
                    return XCTFail("expected invalidUTF8, got \(error)")
                }
            }
        }
    }

    func testZeroControlDimensionRemainsValid() throws {
        let input = dropping("control_gamma.1", from: rows())
        let second = dropping("control_gamma.1", from: rows(offset: 0.1))
        try withFiles([csv(input), csv(second)]) { dir in
            let fit = try DrawsReader.readDirectory(dir: dir.path)
            XCTAssertEqual(fit.K, 0)
            XCTAssertEqual(fit.stackedIndexed("control_gamma", count: 0), Array(repeating: [], count: 6))
        }
    }

    func testCopiedChainDrawsAreRejectedRegardlessOfFilename() throws {
        let input = csv(rows())
        try withFiles([input, input]) { dir in
            XCTAssertThrowsError(try DrawsReader.readDirectory(dir: dir.path)) { error in
                guard let error = error as? DrawsReaderError,
                      case .duplicateChains(let path, let matchingPath) = error else {
                    return XCTFail("expected duplicateChains, got \(error)")
                }
                XCTAssertTrue(path.hasSuffix("mmm_2.csv"))
                XCTAssertTrue(matchingPath.hasSuffix("mmm_1.csv"))
            }
        }
    }

    func testCopiedParameterDrawsWithChangedBookkeepingAreStillRejected() throws {
        let first = rows()
        var second = first
        for column in ["lp__", "divergent__", "mu_scaled.1"] {
            second[1][second[0].firstIndex(of: column)!] = "1"
        }
        try withFiles([csv(first), csv(second)]) { dir in
            XCTAssertThrowsError(try DrawsReader.readDirectory(dir: dir.path)) { error in
                guard let error = error as? DrawsReaderError, case .duplicateChains = error else {
                    return XCTFail("expected duplicateChains, got \(error)")
                }
            }
        }
    }
}

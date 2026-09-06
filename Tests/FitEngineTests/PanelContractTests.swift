import XCTest
@testable import FitEngine

final class PanelContractTests: XCTestCase {
    private let firstDate = "2024-01-01"

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/foreign_drop")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("SignalRigContract-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        try body(copy)
    }

    private func mutate(_ name: String, in directory: URL, _ change: (inout [[String: String]]) -> Void) throws {
        let url = directory.appendingPathComponent(name)
        let table = try CSVReader.read(path: url.path)
        var rows = table.rows
        change(&rows)
        let lines = [table.header.joined(separator: ",")] + rows.map { row in
            table.header.map { row[$0] ?? "" }.joined(separator: ",")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func expectFailure(_ directory: URL, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PanelLoader.load(dropDir: directory.path), file: file, line: line) { error in
            XCTAssertEqual(String(describing: error), message, file: file, line: line)
        }
    }

    private func writeTreatments(in directory: URL, dates: [String], values: [String]) throws {
        var lines = ["date_week,geo,treatment_name,treatment_value"]
        for i in dates.indices {
            lines.append("\(dates[i]),\(i % 2 == 0 ? "east" : "west"),promotion,\(values[i])")
        }
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("non_media_treatments.csv"), atomically: true, encoding: .utf8
        )
    }

    func testUnpaddedKPIDateIsRejected() throws {
        try withFixture { directory in
            try mutate("kpi.csv", in: directory) { $0[0]["date_week"] = "2024-1-1" }
            expectFailure(directory, "kpi.csv: row 1, column \"date_week\": expected a valid YYYY-MM-DD date, got \"2024-1-1\"")
        }
    }

    func testUnpaddedPaidMediaDateIsRejected() throws {
        try withFixture { directory in
            try mutate("paid_media.csv", in: directory) { $0[0]["date_week"] = "2024-1-1" }
            expectFailure(directory, "paid_media.csv: row 1, column \"date_week\": expected a valid YYYY-MM-DD date, got \"2024-1-1\"")
        }
    }

    func testImpossibleCalendarDateIsRejected() throws {
        try withFixture { directory in
            try mutate("kpi.csv", in: directory) { $0[0]["date_week"] = "2024-02-30" }
            expectFailure(directory, "kpi.csv: row 1, column \"date_week\": expected a valid YYYY-MM-DD date, got \"2024-02-30\"")
        }
    }

    func testDailyDatesCannotSatisfyTheWeekRequirement() throws {
        try withFixture { directory in
            try mutate("kpi.csv", in: directory) { rows in
                let dates = Set(rows.compactMap { $0["date_week"] }).sorted()
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let start = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
                var replacements: [String: String] = [:]
                for (offset, old) in dates.enumerated() {
                    let date = calendar.date(byAdding: .day, value: offset, to: start)!
                    let parts = calendar.dateComponents([.year, .month, .day], from: date)
                    replacements[old] = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
                }
                for index in rows.indices { rows[index]["date_week"] = replacements[rows[index]["date_week"]!] }
            }
            expectFailure(directory, "kpi.csv: date_week must be exactly 7 days apart; found 2024-01-01 and 2024-01-02")
        }
    }

    func testMissingKPIWeekIsRejected() throws {
        try withFixture { directory in
            try mutate("kpi.csv", in: directory) { rows in rows.removeAll { $0["date_week"] == "2024-01-08" } }
            expectFailure(directory, "kpi.csv: date_week must be exactly 7 days apart; found 2024-01-01 and 2024-01-15")
        }
    }

    func testMissingWholeSpendWeekIsRejected() throws {
        try withFixture { directory in
            try mutate("paid_media.csv", in: directory) { rows in rows.removeAll { $0["date_week"] == firstDate } }
            expectFailure(directory, "paid_media.csv: date_week must match kpi.csv; missing dates: 2024-01-01. Include explicit zero-spend rows for weeks with no spend.")
        }
    }

    func testUnexpectedPaidDateIsRejected() throws {
        try withFixture { directory in
            try mutate("paid_media.csv", in: directory) { rows in
                var extra = rows[0]
                extra["date_week"] = "2030-01-07"
                rows.append(extra)
            }
            expectFailure(directory, "paid_media.csv: date_week must match kpi.csv; unexpected dates: 2030-01-07. Include explicit zero-spend rows for weeks with no spend.")
        }
    }

    func testDisjointPaidDatesAreRejected() throws {
        try withFixture { directory in
            try mutate("paid_media.csv", in: directory) { rows in
                for index in rows.indices { rows[index]["date_week"] = "2030-01-07" }
            }
            XCTAssertThrowsError(try PanelLoader.load(dropDir: directory.path)) { error in
                guard let error = error as? PanelLoadError,
                      case .dateCoverageMismatch(let file, let missing, let unexpected) = error else {
                    return XCTFail("expected a date coverage failure, got \(error)")
                }
                XCTAssertEqual(file, "paid_media.csv")
                XCTAssertEqual(missing.count, 64)
                XCTAssertEqual(unexpected, ["2030-01-07"])
            }
        }
    }

    func testExplicitZeroSpendWholeWeekIsAccepted() throws {
        try withFixture { directory in
            try mutate("paid_media.csv", in: directory) { rows in
                for index in rows.indices where rows[index]["date_week"] == firstDate { rows[index]["spend"] = "0" }
            }
            let panel = try PanelLoader.load(dropDir: directory.path)
            XCTAssertEqual(panel.T, 64)
            XCTAssertEqual(panel.X[0].reduce(0, +), 0)
            XCTAssertGreaterThan(panel.X[1].reduce(0, +), 0)
        }
    }

    func testControlDateOutsideKPIIsRejected() throws {
        try withFixture { directory in
            try mutate("controls.csv", in: directory) { $0[0]["date_week"] = "2030-01-07" }
            expectFailure(directory, "controls.csv: row 1, date_week 2030-01-07 is not present in kpi.csv")
        }
    }

    func testTreatmentDateOutsideKPIIsRejected() throws {
        try withFixture { directory in
            try writeTreatments(in: directory, dates: ["2030-01-07"], values: ["1"])
            expectFailure(directory, "non_media_treatments.csv: row 1, date_week 2030-01-07 is not present in kpi.csv")
        }
    }

    func testUnpaddedCovariateDatesAreRejected() throws {
        try withFixture { directory in
            try mutate("controls.csv", in: directory) { $0[0]["date_week"] = "2024-1-1" }
            expectFailure(directory, "controls.csv: row 1, column \"date_week\": expected a valid YYYY-MM-DD date, got \"2024-1-1\"")
        }
        try withFixture { directory in
            try writeTreatments(in: directory, dates: ["2024-1-1"], values: ["1"])
            expectFailure(directory, "non_media_treatments.csv: row 1, column \"date_week\": expected a valid YYYY-MM-DD date, got \"2024-1-1\"")
        }
    }

    func testConflictingControlsAcrossGeosAreRejected() throws {
        try withFixture { directory in
            try mutate("controls.csv", in: directory) { $0[1]["control_value"] = "1" }
            expectFailure(directory, "controls.csv: conflicting values for seasonality_index on 2024-01-01; provide one national value or identical values across geos")
        }
    }

    func testConflictingTreatmentsAcrossGeosAreRejected() throws {
        try withFixture { directory in
            try writeTreatments(in: directory, dates: [firstDate, firstDate], values: ["1", "2"])
            expectFailure(directory, "non_media_treatments.csv: conflicting values for promotion on 2024-01-01; provide one national value or identical values across geos")
        }
    }

    func testIdenticalControlRepeatsAreOrderIndependent() throws {
        try withFixture { directory in
            let original = try PanelLoader.load(dropDir: directory.path)
            try mutate("controls.csv", in: directory) { $0.reverse() }
            let reversed = try PanelLoader.load(dropDir: directory.path)
            XCTAssertEqual(original.controlNames, reversed.controlNames)
            XCTAssertEqual(original.Z, reversed.Z)
        }
    }

    func testIdenticalTreatmentRepeatsAreOrderIndependent() throws {
        try withFixture { directory in
            try writeTreatments(in: directory, dates: [firstDate, firstDate, "2024-01-08", "2024-01-08"], values: ["1", "1.0", "2", "2.0"])
            let original = try PanelLoader.load(dropDir: directory.path)
            try mutate("non_media_treatments.csv", in: directory) { $0.reverse() }
            let reversed = try PanelLoader.load(dropDir: directory.path)
            XCTAssertEqual(original.controlNames, reversed.controlNames)
            XCTAssertEqual(original.Z, reversed.Z)
        }
    }
}

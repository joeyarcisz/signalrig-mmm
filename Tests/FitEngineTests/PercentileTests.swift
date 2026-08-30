import XCTest
@testable import FitEngine

final class PercentileTests: XCTestCase {
    // Known values for np.percentile(np.arange(1, 11), q) with numpy's
    // default "linear" interpolation method.
    func testNumpyLinearMethodOnKnownArray() {
        let values: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

        XCTAssertEqual(Percentile.percentile(values, 0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(Percentile.percentile(values, 25), 3.25, accuracy: 1e-12)
        XCTAssertEqual(Percentile.percentile(values, 50), 5.5, accuracy: 1e-12)
        XCTAssertEqual(Percentile.percentile(values, 75), 7.75, accuracy: 1e-12)
        XCTAssertEqual(Percentile.percentile(values, 100), 10.0, accuracy: 1e-12)
    }

    func testUnsortedInputIsSortedFirst() {
        let values: [Double] = [5, 1, 9, 3, 7, 2, 8, 4, 6, 10]
        XCTAssertEqual(Percentile.percentile(values, 50), 5.5, accuracy: 1e-12)
    }

    func testBatchPercentilesMatchIndividual() {
        let values: [Double] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
        let batch = Percentile.percentiles(values, [5, 50, 95])
        XCTAssertEqual(batch[0], Percentile.percentile(values, 5), accuracy: 1e-12)
        XCTAssertEqual(batch[1], Percentile.percentile(values, 50), accuracy: 1e-12)
        XCTAssertEqual(batch[2], Percentile.percentile(values, 95), accuracy: 1e-12)
        // np.percentile([10..100], 5) == 14.5 ; 95 == 95.5
        XCTAssertEqual(batch[0], 14.5, accuracy: 1e-12)
        XCTAssertEqual(batch[2], 95.5, accuracy: 1e-12)
    }

    func testSingleElementArray() {
        XCTAssertEqual(Percentile.percentile([42.0], 5), 42.0, accuracy: 1e-12)
        XCTAssertEqual(Percentile.percentile([42.0], 95), 42.0, accuracy: 1e-12)
    }
}

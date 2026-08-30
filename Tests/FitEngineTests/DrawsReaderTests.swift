import XCTest
@testable import FitEngine

final class DrawsReaderTests: XCTestCase {
    // 29-column synthetic CmdStan CSV: C=2, K=1, T=3. Comments appear at the
    // top, immediately after the header (adaptation info), in the middle of
    // the data rows (not something real CmdStan output does, but the reader
    // must tolerate a comment at any position), and at the end (timing).
    static func syntheticChainCSV(offset: Double) -> String {
        let header = "lp__,accept_stat__,stepsize__,treedepth__,n_leapfrog__,divergent__,energy__,adstock_alpha.1,adstock_alpha.2,hill_kappa.1,hill_kappa.2,hill_slope.1,hill_slope.2,channel_beta.1,channel_beta.2,intercept,trend,fourier_beta.1,fourier_beta.2,fourier_beta.3,fourier_beta.4,control_gamma.1,sigma,media_scaled.1,media_scaled.2,media_scaled.3,mu_scaled.1,mu_scaled.2,mu_scaled.3"
        func row(_ divergent: Int, _ base: Double) -> String {
            let b = base + offset
            let alpha1 = b, alpha2 = b + 0.1
            let kappa1 = b + 0.2, kappa2 = b + 0.3
            let slope1 = b + 0.6, slope2 = b + 0.7
            let beta1 = b - 0.2, beta2 = b - 0.1
            let intercept = b
            let trend = 0.01
            let f1 = 0.02, f2 = 0.03, f3 = 0.04, f4 = 0.05
            let gamma1 = 0.1
            let sigma = 0.02
            let m1 = b, m2 = b + 0.1, m3 = b + 0.2
            let mu1 = b + 0.5, mu2 = b + 0.6, mu3 = b + 0.7
            return "\(b + 1.0),0.9,0.01,4,10,\(divergent),\(-1.0 - b),\(alpha1),\(alpha2),\(kappa1),\(kappa2),\(slope1),\(slope2),\(beta1),\(beta2),\(intercept),\(trend),\(f1),\(f2),\(f3),\(f4),\(gamma1),\(sigma),\(m1),\(m2),\(m3),\(mu1),\(mu2),\(mu3)"
        }
        return """
        # stan_version_major = 2
        # stan_version_minor = 39
        # model = test_model
        \(header)
        # Adaptation terminated
        # Step size = 0.1
        \(row(0, 0.5))
        \(row(1, 0.51))
        # mid-file comment inserted for parser robustness (not real CmdStan output)
        \(row(0, 0.52))
        #
        #  Elapsed Time: 1 seconds (Warm-up)
        #                1 seconds (Sampling)
        #                2 seconds (Total)
        #
        """
    }

    func testSingleChainParsesCommentsHeaderAndDotIndexing() throws {
        let content = Self.syntheticChainCSV(offset: 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("mmm_1.csv").path
        try content.write(toFile: path, atomically: true, encoding: .utf8)

        let chain = try DrawsReader.readChain(path: path)

        XCTAssertEqual(chain.header.count, 29)
        XCTAssertEqual(chain.nDraws, 3, "comment lines (top, mid-file, end) must not count as data rows")
        XCTAssertEqual(chain.columns["adstock_alpha.1"]?.count, 3)
        assertArrayEqual(chain.columns["adstock_alpha.1"], [0.5, 0.51, 0.52], accuracy: 1e-12)
        assertArrayEqual(chain.columns["adstock_alpha.2"], [0.6, 0.61, 0.62], accuracy: 1e-12)
        assertArrayEqual(chain.columns["mu_scaled.3"], [1.2, 1.21, 1.22], accuracy: 1e-12)
        assertArrayEqual(chain.columns["divergent__"], [0, 1, 0], accuracy: 1e-12)
        XCTAssertNil(chain.columns["nonexistent_column"])

        try? FileManager.default.removeItem(at: dir)
    }

    func testDirectoryStacksChainsAndInfersDimensions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Self.syntheticChainCSV(offset: 0).write(toFile: dir.appendingPathComponent("mmm_1.csv").path, atomically: true, encoding: .utf8)
        try Self.syntheticChainCSV(offset: 1).write(toFile: dir.appendingPathComponent("mmm_2.csv").path, atomically: true, encoding: .utf8)
        // Decoys that must be excluded even though they'd match a "*.csv"-ish glob.
        try "not a real chain".write(toFile: dir.appendingPathComponent("mmm_1-diagnostics.csv").path, atomically: true, encoding: .utf8)

        let fit = try DrawsReader.readDirectory(dir: dir.path)

        XCTAssertEqual(fit.nChains, 2)
        XCTAssertEqual(fit.C, 2)
        XCTAssertEqual(fit.T, 3)
        XCTAssertEqual(fit.K, 1)
        XCTAssertEqual(fit.totalDraws, 6)
        XCTAssertEqual(fit.divergences, 2) // 1 divergence per chain

        let alpha = fit.stackedIndexed("adstock_alpha", count: fit.C)
        XCTAssertEqual(alpha.count, 6)
        XCTAssertEqual(alpha[0][0], 0.5, accuracy: 1e-12)   // chain 1, draw 1
        XCTAssertEqual(alpha[3][0], 1.5, accuracy: 1e-12)   // chain 2, draw 1 (offset +1)
    }

    func testTimestampedChainFilenamesAlsoWork() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Self.syntheticChainCSV(offset: 0).write(toFile: dir.appendingPathComponent("mmm-20260101000000_1.csv").path, atomically: true, encoding: .utf8)
        try Self.syntheticChainCSV(offset: 1).write(toFile: dir.appendingPathComponent("mmm-20260101000000_2.csv").path, atomically: true, encoding: .utf8)

        let fit = try DrawsReader.readDirectory(dir: dir.path)
        XCTAssertEqual(fit.nChains, 2)
        XCTAssertEqual(fit.totalDraws, 6)
    }

    func testStdoutAndDiagnosticsFilesExcludedEvenWithBroadGlob() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Self.syntheticChainCSV(offset: 0).write(toFile: dir.appendingPathComponent("mmm_1.csv").path, atomically: true, encoding: .utf8)
        try "log output".write(toFile: dir.appendingPathComponent("mmm_1-stdout.txt").path, atomically: true, encoding: .utf8)
        try "diagnostic stuff".write(toFile: dir.appendingPathComponent("mmm_1-diagnostics.csv").path, atomically: true, encoding: .utf8)

        let files = try DrawsReader.listChainFiles(dir: dir.path, pattern: "*")
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix("mmm_1.csv"))
    }
}

func assertArrayEqual(_ a: [Double]?, _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    guard let a = a else {
        XCTFail("expected non-nil array", file: file, line: line)
        return
    }
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) {
        XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line)
    }
}

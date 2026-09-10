import XCTest
@testable import FitEngine

// The acceptance target is read from CmdStan's own comment header so the
// diagnostics receipt records what the sampler actually ran with.
final class AdaptDeltaReceiptTests: XCTestCase {
    func testParsesTheDeltaCommentLineInBothForms() {
        XCTAssertEqual(ChainDraws.parseAdaptDelta(commentLine: "#       delta = 0.97"), 0.97)
        XCTAssertEqual(ChainDraws.parseAdaptDelta(commentLine: "#       delta = 0.8 (Default)"), 0.8)
        XCTAssertNil(ChainDraws.parseAdaptDelta(commentLine: "#       gamma = 0.05 (Default)"))
        XCTAssertNil(ChainDraws.parseAdaptDelta(commentLine: "#       delta = nonsense"))
        XCTAssertNil(ChainDraws.parseAdaptDelta(commentLine: "# method = sample (Default)"))
    }

    func testChainCSVCarriesItsAcceptanceTarget() throws {
        let csv = """
        # stan_version_major = 2
        #   adapt
        #     engaged = 1 (Default)
        #     gamma = 0.05 (Default)
        #     delta = 0.97
        lp__,accept_stat__,stepsize__,treedepth__,n_leapfrog__,divergent__,energy__,adstock_alpha.1,hill_kappa.1,hill_slope.1,channel_beta.1,intercept,trend,fourier_beta.1,fourier_beta.2,fourier_beta.3,fourier_beta.4,sigma,media_scaled.1,mu_scaled.1
        # Adaptation terminated
        -1.0,0.9,0.1,3,7,0,2.0,0.3,0.4,1.2,0.05,0.5,0.0,0.0,0.0,0.0,0.0,0.03,0.1,0.6
        -1.1,0.9,0.1,3,7,0,2.1,0.31,0.41,1.21,0.051,0.51,0.0,0.0,0.0,0.0,0.0,0.031,0.11,0.61
        #  Elapsed Time: 1 seconds
        """
        let path = NSTemporaryDirectory() + "signalrig-adapt-" + UUID().uuidString + ".csv"
        try csv.write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let chain = try DrawsReader.readChain(path: path)
        XCTAssertEqual(chain.adaptDelta, 0.97)
        XCTAssertEqual(chain.nDraws, 2)
    }
}

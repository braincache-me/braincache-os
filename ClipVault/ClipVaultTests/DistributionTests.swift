import XCTest
@testable import ClipVault

// MARK: - Info.plist Distribution Keys Tests

final class InfoPlistDistributionTests: XCTestCase {

    func testLSUIElementIsTrue() {
        let bundle = Bundle.main
        let value = bundle.object(forInfoDictionaryKey: "LSUIElement")
        // Can be Bool or String "YES" depending on how the plist is read
        let isTrue: Bool
        if let boolVal = value as? Bool {
            isTrue = boolVal
        } else if let strVal = value as? String {
            isTrue = (strVal == "YES" || strVal == "1")
        } else {
            isTrue = false
        }
        XCTAssertTrue(isTrue, "LSUIElement must be YES for an agent app")
    }

    func testBundleIDIsSet() {
        let bundleID = Bundle.main.bundleIdentifier
        XCTAssertNotNil(bundleID)
        XCTAssertFalse(bundleID?.isEmpty ?? true)
    }
}

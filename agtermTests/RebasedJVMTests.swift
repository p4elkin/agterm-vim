import XCTest
import RebasedJNI
@testable import agterm

final class RebasedJVMTests: XCTestCase {
    func testMissingLibraryReturnsItsDlopenErrorAndCanRetry() throws {
        let path = "/tmp/agterm-no-such-jvm/libjvm.dylib"
        for _ in 0..<2 {
            let error = try XCTUnwrap(rb_start(path, nil, 0, "com.intellij.idea.Main"))
            let text = String(cString: error)
            XCTAssertTrue(text.contains("dlopen"), text)
            XCTAssertTrue(text.contains(path), text)
            XCTAssertFalse(rb_jvm_created())
        }
    }

    func testMissingCreateSymbolAlsoLeavesTheShimStartable() throws {
        for _ in 0..<2 {
            let error = try XCTUnwrap(rb_start("/usr/lib/libSystem.B.dylib", nil, 0, "com.intellij.idea.Main"))
            XCTAssertTrue(String(cString: error).contains("JNI_CreateJavaVM"))
            XCTAssertFalse(rb_jvm_created())
        }
    }

    func testStartedOnceGuardRefusesAnotherJVM() throws {
        rb_test_set_started_once(true)
        defer { rb_test_set_started_once(false) }
        let error = try XCTUnwrap(rb_start("/tmp/no-jvm", nil, 0, "com.intellij.idea.Main"))
        XCTAssertEqual(String(cString: error), "Rebased JVM has already been created")
    }

    func testBridgeCallsBeforeStartupReturnAnError() throws {
        XCTAssertEqual(String(cString: try XCTUnwrap(rb_bridge_call("hide", "/repo"))), "Rebased JVM has not started")
        XCTAssertEqual(String(cString: try XCTUnwrap(rb_register_events(nil))), "Rebased JVM has not started")
    }
}

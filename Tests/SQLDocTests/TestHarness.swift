import Foundation

public func expect(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if !condition {
        fatalError("Assertion failed: \(message) at \(file):\(line)")
    }
}

public func expectEqual<T: Equatable>(_ a: T?, _ b: T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if a != b {
        fatalError("Expected \(String(describing: a)) == \(String(describing: b)). \(message) at \(file):\(line)")
    }
}

public func expectTrue(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    expect(condition == true, message, file: file, line: line)
}

public func expectFalse(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    expect(condition == false, message, file: file, line: line)
}

public func expectNotNil<T>(_ val: T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    expect(val != nil, "Expected non-nil value. \(message)", file: file, line: line)
}

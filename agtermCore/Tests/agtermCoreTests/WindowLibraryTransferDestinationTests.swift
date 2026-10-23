import Foundation
import Testing
@testable import agtermCore

@MainActor
final class WindowLibraryTransferDestinationTests {
    private let directory: URL
    private let source = UUID(uuidString: "5E5E0000-0000-4000-8000-000000000001")!
    private let open = UUID(uuidString: "A1A10000-0000-4000-8000-000000000002")!
    private let closed = UUID(uuidString: "B2B20000-0000-4000-8000-000000000003")!
    private let cafeFirst = UUID(uuidString: "CAFE0000-0000-4000-8000-000000000004")!
    private let cafeSecond = UUID(uuidString: "CAFE1111-0000-4000-8000-000000000005")!
    private let hexNamed = UUID(uuidString: "D4D40000-0000-4000-8000-000000000006")!
    private let twinFirst = UUID(uuidString: "E5E50000-0000-4000-8000-000000000007")!
    private let twinSecond = UUID(uuidString: "F6F60000-0000-4000-8000-000000000008")!

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-transfer-dest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = WindowsIndex(frontmost: source, windows: [
            WindowEntry(id: source, name: "source", isOpen: true),
            WindowEntry(id: open, name: "work", isOpen: true),
            WindowEntry(id: closed, name: "archive", isOpen: false),
            WindowEntry(id: cafeFirst, name: "cafe one", isOpen: false),
            WindowEntry(id: cafeSecond, name: "cafe two", isOpen: false),
            WindowEntry(id: hexNamed, name: "a1a1", isOpen: false),
            WindowEntry(id: twinFirst, name: "twin", isOpen: true),
            WindowEntry(id: twinSecond, name: "twin", isOpen: false),
        ])
        try JSONEncoder().encode(index).write(to: directory.appendingPathComponent("windows.json"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func resolve(_ raw: String) -> Result<TransferDestination, TransferRefusal> {
        WindowLibrary(directory: directory).resolveTransferDestination(raw, source: source)
    }

    private func refusal(_ raw: String) -> String? {
        guard case .failure(let refusal) = resolve(raw) else { return nil }
        return refusal.message
    }

    @Test func newNamesANewWindow() {
        #expect(resolve("new") == .success(.new))
    }

    @Test func anOpenWindowResolvesByExactName() {
        #expect(resolve("work") == .success(.window(open)))
    }

    @Test func aClosedWindowResolvesByExactName() {
        let library = WindowLibrary(directory: directory)
        #expect(!library.isOpen(closed))
        #expect(library.resolveTransferDestination("archive", source: source) == .success(.window(closed)))
    }

    @Test func aNameIsSanitizedAndTrimmedLikeAStoredName() {
        #expect(resolve("  arch\u{07}ive\n ") == .success(.window(closed)))
    }

    @Test func aFullIdResolvesInEitherCase() {
        #expect(resolve(open.uuidString) == .success(.window(open)))
        #expect(resolve(open.uuidString.lowercased()) == .success(.window(open)))
    }

    @Test func aUniqueIdPrefixResolves() {
        #expect(resolve("cafe0") == .success(.window(cafeFirst)))
    }

    @Test func anAmbiguousIdPrefixGivesTheCanonicalError() {
        #expect(refusal("cafe") == ControlResolve.ambiguousMessage(noun: "window", target: "cafe",
                                                                    hits: [cafeFirst, cafeSecond]))
    }

    @Test func aNameThatIsAlsoAnotherWindowsIdPrefixIsAmbiguous() {
        #expect(refusal("a1a1") == "ambiguous window: a1a1 matches a name and an id prefix")
    }

    @Test func aNameSharedByTwoWindowsListsBothIds() throws {
        let message = try #require(refusal("twin"))
        #expect(message.hasPrefix("ambiguous window name: twin"))
        #expect(message.contains(twinFirst.uuidString))
        #expect(message.contains(twinSecond.uuidString))
    }

    @Test func anUnknownWindowGivesTheCanonicalNotFound() {
        #expect(refusal("nowhere") == "no such window: nowhere")
    }

    @Test func theSourceWindowIsRefusedByNameIdOrActive() {
        #expect(refusal("source") == "same window")
        #expect(refusal(source.uuidString) == "same window")
        #expect(refusal("active") == "same window")
    }
}

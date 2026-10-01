import agtermCore
import Foundation
import os

private let bookLogger = Logger(subsystem: "com.umputun.agterm", category: "RemoteRowBook")

/// Keeps `remote-rows.json` in step with the attached rows: a debounced walk of the whole library after every
/// tree change or finalized soft close, and one write from `applicationWillTerminate`. `isTerminating` stops every write after that
/// one, so quit teardown closing windows and stores cannot empty the book.
@MainActor
final class RemoteRowBookWriter {
    private let library: WindowLibrary
    private let book: RemoteRowBook
    private let delay: TimeInterval
    private let debouncer = Debouncer()
    private var previous: [RemoteRowBook.Record]

    /// Chains the library's event observer, so it must be created after anything else that sets it.
    init(library: WindowLibrary, book: RemoteRowBook, delay: TimeInterval = 0.5) {
        self.library = library
        self.book = book
        self.delay = delay
        previous = book.load()
        let earlier = library.onControlEvent
        library.onControlEvent = { [weak self] event in
            earlier?(event)
            if event.kind == .treeChanged { self?.schedule() }
        }
        let finalized = library.onSessionFinalized
        library.onSessionFinalized = { [weak self] id in
            finalized?(id)
            self?.schedule()
        }
    }

    func schedule() {
        guard !library.isTerminating else { return }
        debouncer.schedule(after: delay) { [weak self] in self?.write() }
    }

    func write() {
        guard !library.isTerminating else { return }
        let records = RemoteRowBook.records(from: library, previous: previous)
        guard records != previous else { return }
        do {
            try book.save(records)
            previous = records
        } catch {
            bookLogger.error("remote rows not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}

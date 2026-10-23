import Foundation
import Testing
@testable import agtermCore

struct RebasedMirrorMarkerTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func roundTripsThroughTheHashDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = RebasedMirrorMarker(source: "p4linux:/home/s/jackrabbit", lastOpened: Date(timeIntervalSince1970: 1_791_000_000))
        try marker.write(to: directory)
        #expect(RebasedMirrorMarker.read(from: directory) == marker)
    }

    @Test func theFileHoldsTheSourceAndAnISO8601LastOpenedOnly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try RebasedMirrorMarker(source: "p4linux:/r", lastOpened: Date(timeIntervalSince1970: 1_791_000_000)).write(to: directory)
        let data = try Data(contentsOf: directory.appendingPathComponent(RebasedMirrorMarker.fileName))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["source", "lastOpened"])
        #expect(object["source"] as? String == "p4linux:/r")
        let lastOpened = try #require(object["lastOpened"] as? String)
        #expect(ISO8601DateFormatter().date(from: lastOpened) == Date(timeIntervalSince1970: 1_791_000_000))
    }

    @Test func corruptJSONReadsAsNil() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{\"source\":".utf8).write(to: directory.appendingPathComponent(RebasedMirrorMarker.fileName))
        #expect(RebasedMirrorMarker.read(from: directory) == nil)
    }

    @Test func aTouchWritesTheSourceAndNowIntoTheHashDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        RebasedMirrorMarker.touch(hashDirectory: directory, source: "p4linux:/home/s/repo", now: now)
        #expect(RebasedMirrorMarker.read(from: directory) == RebasedMirrorMarker(source: "p4linux:/home/s/repo", lastOpened: now))
    }

    @Test func aTouchWithoutTheHashDirectoryWritesNothing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("0a1b2c3d", isDirectory: true)
        RebasedMirrorMarker.touch(hashDirectory: missing, source: "p4linux:/r", now: Date(timeIntervalSince1970: 1_791_000_000))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func aMissingFileReadsAsNil() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(RebasedMirrorMarker.read(from: directory) == nil)
    }
}

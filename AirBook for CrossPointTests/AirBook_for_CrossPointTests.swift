//
//  AirBook_for_CrossPointTests.swift
//  AirBook for CrossPointTests
//
//  Created by Ale on 08/06/26.
//

import Foundation
import Testing
@testable import AirBook_for_CrossPoint

struct AirBook_for_CrossPointTests {

    @Test func firmwareInfoParsesStorageFields() async throws {
        let payload = "fw=1.5.0-airbook.7\nproto=2\ncaps=book,sync,ota,browse\nused_kb=51200\nbooks=12\nfree_kb=1048576\n"
        let info = try #require(DeviceFirmwareInfo.parse(Data(payload.utf8)))
        #expect(info.version == "1.5.0-airbook.7")
        #expect(info.usedKB == 51200)
        #expect(info.bookCount == 12)
        #expect(info.freeKB == 1_048_576)
    }

    @Test func firmwareInfoToleratesMissingFreeKB() async throws {
        let payload = "fw=1.4.0\nproto=2\ncaps=book,sync\n"
        let info = try #require(DeviceFirmwareInfo.parse(Data(payload.utf8)))
        #expect(info.freeKB == nil)
    }

    @MainActor
    @Test func importRejectsDuplicateContent() async throws {
        let libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("airbook-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: libraryRoot) }
        let store = BookStore(documentsDirectory: libraryRoot)
        // Unique content per run so leftovers from earlier runs can't collide.
        var content = Data("duplicate-check \(UUID().uuidString)\n".utf8)
        content.append(Data(count: 2048))

        let tmp = FileManager.default.temporaryDirectory
        let first = tmp.appendingPathComponent("dup-a-\(UUID().uuidString).txt")
        let second = tmp.appendingPathComponent("dup-b-\(UUID().uuidString).txt")
        try content.write(to: first)
        try content.write(to: second)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let book = try store.importBook(from: first)
        defer { store.deleteBook(book) }

        #expect(throws: BookImportError.self) {
            try store.importBook(from: second)
        }
    }

    @MainActor
    @Test func deletingSentBookPersistsDeviceTombstone() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("airbook-delete-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-me-\(UUID().uuidString).txt")
        try Data("delete propagation".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let store = BookStore(documentsDirectory: root)
        let book = try store.importBook(from: source)
        store.markUploaded(book)
        store.deleteBook(book)

        #expect(store.pendingEntryDeletions() == [book.id])

        let relaunched = BookStore(documentsDirectory: root)
        #expect(relaunched.books.isEmpty)
        #expect(Set(relaunched.pendingEntryDeletions()) == [book.id])
    }

    @MainActor
    @Test func freedDeviceFileStaysEntryOnlyAcrossRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("airbook-free-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("free-me-\(UUID().uuidString).txt")
        try Data("keep the entry".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let store = BookStore(documentsDirectory: root)
        let book = try store.importBook(from: source)
        store.markUploaded(book)
        store.queueFileRemoval(book)
        store.markFileRemovedFromDevice(bookID: book.id)

        let relaunched = BookStore(documentsDirectory: root)
        let restoredBook = try #require(relaunched.books.first(where: { $0.id == book.id }))
        #expect(relaunched.deviceState(for: restoredBook) == .entryOnly)
        #expect(!relaunched.isFileRemovalQueued(restoredBook))
        #expect(!relaunched.booksNeedingUpload().contains(where: { $0.id == book.id }))
    }

}

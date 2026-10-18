//
//  PhotoRefreshTests.swift
//  WorkoutTrackerTests
//
//  A sheet import fetches every row's photo_url again: a new image replaces
//  the photo, the same image changes nothing, and a photo set in the app is
//  never replaced. (The download itself isn't tested here.)
//

import XCTest
import SwiftData
@testable import WorkoutTracker

@MainActor
final class PhotoRefreshTests: XCTestCase {

    private let link = "https://example.com/quad.png"
    private var csv: String {
        "exercise,kind,hold_seconds,reps,sets,per_side,photo_url\nStanding Quad Stretch,static,30,1,1,left_right,\(link)\n"
    }

    private func importSheet(_ ctx: ModelContext) throws -> [(id: UUID, raw: String)] {
        try CSVExerciseImporter(ctx, group: .stretching, replaceExisting: true, saves: false)
            .importText(csv).photoDownloads
    }

    private func quad(_ ctx: ModelContext) throws -> Exercise {
        try XCTUnwrap(try ctx.fetch(FetchDescriptor<Exercise>()).first { $0.name == "Standing Quad Stretch" })
    }

    func testReimportFetchesAPhotoTheSheetPutThere() throws {
        let ctx = TestSupport.makeContext()
        XCTAssertEqual(try importSheet(ctx).map(\.raw), [link])         // new exercise
        let ex = try quad(ctx)
        XCTAssertEqual(CSVExerciseImporter.applyDownloadedPhoto(Data([1, 2, 3]), to: ex), .added)
        try ctx.save()

        XCTAssertEqual(try importSheet(ctx).map(\.raw), [link], "re-checked on every import")
    }

    func testAPhotoSetInTheAppIsNotFetchedOrReplaced() throws {
        let ctx = TestSupport.makeContext()
        _ = try importSheet(ctx)
        let ex = try quad(ctx)
        ex.photoData = Data([9, 9])
        ex.photoSetInApp = true
        try ctx.save()

        XCTAssertTrue(try importSheet(ctx).isEmpty)
        // Picked in the app while a download was under way: still kept.
        XCTAssertEqual(CSVExerciseImporter.applyDownloadedPhoto(Data([1, 2, 3]), to: ex), .unchanged)
        XCTAssertEqual(ex.photoData, Data([9, 9]))
    }

    func testOnlyAChangedImageReplacesThePhoto() throws {
        let ctx = TestSupport.makeContext()
        _ = try importSheet(ctx)
        let ex = try quad(ctx)
        XCTAssertEqual(CSVExerciseImporter.applyDownloadedPhoto(Data([1, 2, 3]), to: ex), .added)
        XCTAssertEqual(CSVExerciseImporter.applyDownloadedPhoto(Data([1, 2, 3]), to: ex), .unchanged)
        XCTAssertEqual(CSVExerciseImporter.applyDownloadedPhoto(Data([4, 5, 6]), to: ex), .updated)
        XCTAssertEqual(ex.photoData, Data([4, 5, 6]))
    }

    func testTheInAppFlagSurvivesABackup() throws {
        let ctx = TestSupport.makeContext()
        _ = try importSheet(ctx)
        let ex = try quad(ctx)
        ex.photoData = Data([9, 9]); ex.photoSetInApp = true
        try ctx.save()
        let data = try ExportImportService(ctx).exportJSONData()

        let restored = TestSupport.makeContext()
        _ = try ExportImportService(restored).importJSON(data)
        XCTAssertTrue(try quad(restored).photoSetInApp)
    }

    func testPhotoSummaryLeavesOutZeroCounts() {
        let status = PhotoImportStatus()
        status.begin(4)
        status.record(.added); status.record(.unchanged); status.record(.unchanged); status.record(.updated)
        XCTAssertEqual(ImportExportView.photoSummary(status), "1 added · 1 updated · 2 unchanged")
        XCTAssertTrue(status.isFinished)
    }
}

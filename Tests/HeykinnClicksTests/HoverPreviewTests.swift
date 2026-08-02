import XCTest
import AVFoundation
@testable import HeykinnClicks

@MainActor
final class HoverPreviewTests: XCTestCase {

    private func makeVideo() throws -> URL {
        // A real, tiny movie so AVPlayer has something valid to open.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer)
        if let buffer {
            for frame in 0..<4 {
                while !input.isReadyForMoreMediaData { usleep(1000) }
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 4))
            }
        }
        input.markAsFinished()
        let done = expectation(description: "written")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 10)
        return url
    }

    func testHoverStartsMutedLoopingPlaybackThenTearsDown() async throws {
        let url = try makeVideo()
        let controller = HoverPreviewController()
        XCTAssertNil(controller.player, "Nothing should play before a hover")

        controller.hoverBegan(url: url)
        try await Task.sleep(for: .milliseconds(700))
        let player = try XCTUnwrap(controller.player, "Hover should start playback after its delay")
        XCTAssertTrue(player.isMuted, "A grid preview must never make noise")
        XCTAssertEqual(player.actionAtItemEnd, .none, "Preview should loop, not freeze on the last frame")

        controller.hoverEnded()
        XCTAssertNil(controller.player, "Leaving the cell must release the player")
    }

    func testBriefHoverNeverStartsPlayback() async throws {
        let url = try makeVideo()
        let controller = HoverPreviewController()

        // Pointer sweeps across the cell and leaves before the start delay.
        controller.hoverBegan(url: url)
        try await Task.sleep(for: .milliseconds(80))
        controller.hoverEnded()

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(
            controller.player,
            "Sweeping across the grid must not spin up a player per cell"
        )
    }

    func testHoverWithNoReachableFileDoesNothing() async throws {
        let controller = HoverPreviewController()
        controller.hoverBegan(url: nil)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(controller.player, "An unplugged drive should leave the still in place")
    }
}

//
//  VideoEncoder.swift
//  StrayScanner
//
//  Created by Kenneth Blomqvist on 12/30/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import Foundation
import ARKit

struct VideoEncoderInput {
    let buffer: CVPixelBuffer
    let time: TimeInterval // Relative to boot time.
}

class VideoEncoder {
    enum EncodingStatus {
        case allGood
        case error
    }
    
    private var videoWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var videoAdapter: AVAssetWriterInputPixelBufferAdaptor?
    private let timeScale: CMTimeScale
    public let width: CGFloat
    public let height: CGFloat
    private let systemBootedAt: TimeInterval
    private var done: Bool = false
    private var previousFrame: Int = -1
    public var filePath: URL
    public var status: EncodingStatus = EncodingStatus.allGood
    /// Bit rate asked for (nil = iOS decides) and how many frames per second are actually saved.
    private let requestedBitRate: Int?
    private let savedFramesPerSecond: Int
    /// Bit rate the writer accepted, for capture_settings.json.
    public private(set) var appliedBitRate: Int?

    init(file: URL, width: CGFloat, height: CGFloat, framesPerSecond: Int = 60, bitRate: Int? = nil,
         savedFramesPerSecond: Int? = nil) {
        self.timeScale = CMTimeScale(max(framesPerSecond, 1))
        self.systemBootedAt = ProcessInfo.processInfo.systemUptime
        self.filePath = file
        self.width = width
        self.height = height
        self.requestedBitRate = bitRate
        self.savedFramesPerSecond = max(savedFramesPerSecond ?? framesPerSecond, 1)
        initializeFile()
    }

    func finishEncoding() {
        self.doneRecording()
    }

    func add(frame: VideoEncoderInput, currentFrame: Int) {
        previousFrame = currentFrame
        guard let input = videoWriterInput, videoWriter?.status == .writing else {
            // The writer failed (disk full, encoder error): nothing more can be saved. Don't wait forever.
            status = .error
            return
        }
        while !input.isReadyForMoreMediaData {
            // Encoder busy: wait (frames are dropped upstream, before they get a number, when the queue backs up).
            // A failed writer never becomes ready again, and waiting for it would hang the app at Stop.
            if videoWriter?.status != .writing {
                status = .error
                return
            }
            Thread.sleep(until: Date() + TimeInterval(0.01))
        }
        encode(frame: frame, frameNumber: currentFrame)
    }

    private func initializeFile() {
        do {
            videoWriter = try AVAssetWriter(outputURL: self.filePath, fileType: .mp4)
            // stray-scanner-sf: write the movie in 1 s fragments so the video stays playable
            // up to the last fragment if the app is killed (e.g. by overheating) mid-recording.
            videoWriter?.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            var settings: [String : Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: self.width,
                AVVideoHeightKey: self.height
            ]
            // stray-scanner-sf: an explicit bit rate (Video quality setting). iOS's own default is tuned for small
            // files and smears fine texture, which the splat training then learns. One key frame per second and no
            // frame reordering keep decoding on the PC simple.
            if let bitRate = requestedBitRate {
                let compression: [String : Any] = [
                    AVVideoAverageBitRateKey: bitRate,
                    AVVideoExpectedSourceFrameRateKey: savedFramesPerSecond,
                    AVVideoMaxKeyFrameIntervalKey: savedFramesPerSecond,
                    AVVideoAllowFrameReorderingKey: false
                ]
                var tuned = settings
                tuned[AVVideoCompressionPropertiesKey] = compression
                if videoWriter?.canApply(outputSettings: tuned, forMediaType: .video) == true {
                    settings = tuned
                    appliedBitRate = bitRate
                } else {
                    print("Video encoder refused the bit rate settings; using the defaults.")
                }
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            input.mediaTimeScale = timeScale
            input.performsMultiPassEncodingIfSupported = false
            videoAdapter = createVideoAdapter(input)
            if videoWriter!.canAdd(input) {
                videoWriter!.add(input)
                videoWriterInput = input
                videoWriter!.startWriting()
                videoWriter!.startSession(atSourceTime: .zero)
            } else {
                print("Can't create writer.")
            }
        } catch let error as NSError {
            print("Creating AVAssetWriter failed. \(error), \(error.userInfo)")
        }
    }

    private func encode(frame: VideoEncoderInput, frameNumber: Int) {
        let image: CVPixelBuffer = frame.buffer
        let time = CMTime(value: Int64(frameNumber), timescale: timeScale)
        let success = videoAdapter?.append(image, withPresentationTime: time) ?? false
        if !success {
            print("Pixel buffer could not be appended. \(videoWriter?.error?.localizedDescription ?? "")")
            if videoWriter?.status == .failed { status = .error }
        }
    }

    private func doneRecording() {
        guard let writer = videoWriter else {
            self.status = .error
            return
        }
        if writer.status == .failed {
            print("Something went wrong when writing video. \(writer.error?.localizedDescription ?? "")")
            self.status = .error
        } else {
            videoWriterInput?.markAsFinished()
            // Wait until the file is complete: the scan may be zipped and sent to the PC right after this returns.
            let finished = DispatchSemaphore(value: 0)
            writer.finishWriting { [weak self] in
                if writer.status == .failed { self?.status = .error }
                self?.videoWriter = nil
                self?.videoWriterInput = nil
                self?.videoAdapter = nil
                finished.signal()
            }
            _ = finished.wait(timeout: .now() + 8)
        }
    }

    private func createVideoAdapter(_ input: AVAssetWriterInput) -> AVAssetWriterInputPixelBufferAdaptor {
        return AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    }
}

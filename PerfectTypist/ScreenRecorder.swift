/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A model object that provides the interface to capture screen content and system audio.
*/
import Foundation
import ScreenCaptureKit
import Combine
import OSLog
import SwiftUI
import AVFoundation
import VideoToolbox

/* 
 
 doc:
 https://developer.apple.com/documentation/videotoolbox?language=objc
 
 https://developer.apple.com/videos/play/wwdc2014/513/
 
 CVPixelBuffer - uncompressed pixel data with info about what it is
 CVPixelBufferPool to be able to allocate/deallocate easily
 pixelBufferAttributes is dictionary of useful info like with/height and format
 CMBlockBuffer wraps various raw data
 CMSampleBuffer is compressed video frame (holding CMBlockBuffer) OR uncompressed raster image (holding CMPixelBuffer)
 CMClockGetHostTimeClock() wrapper around mach_absolute_time
 CMTimeBase is more controlled access to clock
 
 Compressing Video into a file: Sequence of CVPixelBuffers, goes into AVAssetWriter has a video encoder which puts the frames into CMSampleBuffers.
 AVAssetWriter:
 WWDC 2013 -Moving to AVKit and AVFoundation
 WWDC 2011 -Working with Media in AVFoundation
 
 But if you want direct access to those compressed sample buffers …
 So you get the video encoder via a VTCompressionSession, which returns CMSampleBuffers.
 You'll need dimension, what format (…CodecType_H264), optionally PixelBufferAttributes describing source, VTCompressionOutputCallback (Modern equivalent?)
 After creating the VTCompressionSession you need to configure it. Using VTSessionSetProperty() calls, like _AllowFrameReordering, averageBitRate,
 entropyMode, RealTime to tell encoder this is realtime data, ProFileLevel - ??? 
 Feeding VTCompressionSession: use VTCompressionSessionEncodeFrame with CVPixelBuffers with their presentationTime
 Then use VTCompressionSessionCompleteFrames() to finish pending frames, to have it emit all the frames it's received so far
 VTCompressionSessionOutputCallback to receive output CMSampleBuffer, error codes, dropped frames . Frames emitted in decodeOrder - is this significant? 
 
 WWDC session then talks about conversing H264 sample buffers to elementary streams for going to the network. Is this relevant? Or how to we then go to a file after we've processed things?
 
 Then it talks about multi-pass encoding. Maybe we could encode at a high quality, high bit rate for our buffer, but then later on, at the end of
 the recording, re-encode for a better bit rate?
 Maybe look at this later. We get into the details at about 39 minutes into WWDC 2014 #513
 AVAssetReader, AVAssetWriter
 Then again, multi-pass is best for varying complexity source material, and a screencast with you typing is not going to be that varying.
 
 
 Of interest:
 
 VTCompressionSessionGetPixelBufferPool
 
 */

/// A provider of audio levels from the captured samples.
class AudioLevelsProvider: ObservableObject {
    @Published var audioLevels = AudioLevels.zero
}

@MainActor
class ScreenRecorder: NSObject,
                      ObservableObject,
                      SCContentSharingPickerObserver {
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var hasSession = false
    
    private var keyboardMonitor: KeyboardMonitor?
    private var circularBuffer: CircularBuffer<CMSampleBuffer>?   // allocated when we start capturing

    var compressionSession: VTCompressionSession?
    
    /// The supported capture types.
    enum CaptureType {
        case display
        case window
    }
    
    private let logger = Logger()
    
    @Published var isRunning = false
    var bufferInSeconds: Double = 10.0
    
    var frameInterval: CMTime { CMTime(value: 1, timescale: CMTimeScale(framesPerSecond)) }
    var framesPerSecond: Double = 60.0
    
    // MARK: - Video Properties
    @Published var captureType: CaptureType = .display {
        didSet { updateEngine() }
    }
    
    @Published var selectedDisplay: SCDisplay? {
        didSet { updateEngine() }
    }
    
    @Published var selectedWindow: SCWindow? {
        didSet { updateEngine() }
    }
    
    @Published var isAppExcluded = true {
        didSet { updateEngine() }
    }

    // MARK: - SCContentSharingPicker Properties
    @Published var maximumStreamCount = Int() {
        didSet { updatePickerConfiguration() }
    }
    @Published var excludedWindowIDsSelection = Set<Int>() {
        didSet { updatePickerConfiguration() }
    }

    @Published var excludedBundleIDsList = [String]() {
        didSet { updatePickerConfiguration() }
    }

    @Published var allowsRepicking = true {
        didSet { updatePickerConfiguration() }
    }

    @Published var allowedPickingModes = SCContentSharingPickerMode() {
        didSet { updatePickerConfiguration() }
    }
    @Published var contentSize = CGSize(width: 1, height: 1)
    private var scaleFactor: Int { Int(NSScreen.main?.backingScaleFactor ?? 2) }
    
    /// A view that renders the screen content.
    lazy var capturePreview: CapturePreview = {
        CapturePreview()
    }()
    private let screenRecorderPicker = SCContentSharingPicker.shared
    private var availableApps = [SCRunningApplication]()
    @Published private(set) var availableDisplays = [SCDisplay]()
    @Published private(set) var availableWindows = [SCWindow]()
    @Published private(set) var pickerUpdate: Bool = false // Update the running stream immediately with picker selection
    private var pickerContentFilter: SCContentFilter?
    private var shouldUsePickerFilter = false
    /// - Tag: TogglePicker
    @Published var isPickerActive = false {
        didSet {
            if isPickerActive {
                logger.info("Picker is active")
                self.initializePickerConfiguration()
                self.screenRecorderPicker.isActive = true
                self.screenRecorderPicker.add(self)
            } else {
                logger.info("Picker is inactive")
                self.screenRecorderPicker.isActive = false
                self.screenRecorderPicker.remove(self)
            }
        }
    }

    // MARK: - Audio Properties
    @Published var isAudioCaptureEnabled = true {
        didSet {
            updateEngine()
            if isAudioCaptureEnabled {
                startAudioMetering()
            } else {
                stopAudioMetering()
            }
        }
    }
    @Published var isAppAudioExcluded = false { didSet { updateEngine() } }
    @Published private(set) var audioLevelsProvider = AudioLevelsProvider()
    // A value that specifies how often to retrieve calculated audio levels.
    private let audioLevelRefreshRate: TimeInterval = 0.1
    private var audioMeterCancellable: AnyCancellable?
    
    // The object that manages the SCStream.
    private let captureEngine = CaptureEngine()
        
    private var isSetup = false
    
    // Combine subscribers.
    private var subscriptions = Set<AnyCancellable>()
    
    var canRecord: Bool {
        get async {
            do {
                // If the app doesn't have screen recording permission, this call generates an exception.
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                return true
            } catch {
                return false
            }
        }
    }
    
    func monitorAvailableContent() async {
        // Refresh the lists of capturable content.
        await self.refreshAvailableContent()
        Timer.publish(every: 3, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.refreshAvailableContent()
            }
        }
        .store(in: &subscriptions)
    }
    
    /// Starts capturing screen content.
    func start() async {
        // Exit early if already running.
        guard !isRunning else { return }
        
        if !isSetup {
            // Starting polling for available screen content.
            await monitorAvailableContent()
            isSetup = true
        }
        
        // If the user enables audio capture, start monitoring the audio stream.
        if isAudioCaptureEnabled {
            startAudioMetering()
        }
        
        do {
            let config = streamConfiguration

            /// initialize our VTCompressionSession with H264 as our desired codec.
            /// You can also use VTSessionSetProperty()to specify additional encoding settings (bitrate, framerate, pixel formats, etc.).

            compressionSession = VTCompressionSession.new(width: Int32(config.width),
                                                                    height: Int32(config.height),
                                                                    codec: kCMVideoCodecType_H264,
                                                                    callback: nil) 
            guard let compressionSession else {
                fatalError("can't create session")
            }
            compressionSession.isRealtime = true
            compressionSession.profile = kVTProfileLevel_H264_High_AutoLevel // ???
            compressionSession.averageBitrate = 4000            // Just spitballing. Make this a user input?
            compressionSession.maxKeyframeIntervalDuration = 0 // No limit. Not sure if I want to specify.
            compressionSession.isRealtime = true    // we are compressing in real time, not necessarily writing to file in real time (at first)
            compressionSession.prepare()
                        
            let numberOfSamplesInBuffer: Int = Int(bufferInSeconds * Double(frameInterval.timescale) / Double(frameInterval.value))
            self.circularBuffer = CircularBuffer<CMSampleBuffer>(capacity: numberOfSamplesInBuffer)
            guard let circularBuffer else { 
                print("No circular buffer")
                return
            }
            keyboardMonitor = KeyboardMonitor(circularBuffer: circularBuffer, compressionSession: compressionSession)
            
            beginWriting(width: config.width, height: config.height) // already has scale factor baked into dimensions from config
            keyboardMonitor?.activateMonitor(true)
            
            let filter = contentFilter
            // Update the running state.
            isRunning = true
            setPickerUpdate(false)
            // Start the stream and await new video frames.
            for try await frame in captureEngine.startCapture(configuration: config, filter: filter) {
                capturePreview.updateFrame(frame)
                
                let sampleBuffer: CMSampleBuffer = frame.sampleBuffer
                guard let image: CVImageBuffer = sampleBuffer.imageBuffer else { throw VideoToolboxError.errorCreatingImageBuffer }
                let sampleDuration: CMTime = sampleBuffer.duration
                let duration: CMTime = sampleDuration // .value > 0 ? sampleDuration : frameInterval // don't use CMTimeMaximum - 0 is the maximum????
                try compressionSession.encode(imageBuffer: image,
                                               presentationTimestamp: sampleBuffer.presentationTimeStamp,
                                               duration: duration) { [weak self] (status: OSStatus, infoFlags: VTEncodeInfoFlags, encodedSampleBuffer: CMSampleBuffer?) in // VTCompressionOutputHandler
                    if let self, let encodedSampleBuffer, let circularBuffer = self.circularBuffer {
                        // print("🦋 Writing sampleBuffer to circularBuffer index \(circularBuffer.writeIndex), its timestamp = \(encodedSampleBuffer.presentationTime)")
                        let displacedSampleBuffer: CMSampleBuffer? = circularBuffer.write(encodedSampleBuffer)
                        if let displacedSampleBuffer {
                            print("👻 Displaced buffer @ \(displacedSampleBuffer.presentationTime)")
                            self.writeToFile(sampleBuffer: displacedSampleBuffer)
                        }
                    } else {
                        print("no encodedSampleBuffer to encode")
                    }
                }

                if contentSize != frame.size {
                    // Update the content size if it changed.
                    contentSize = frame.size
                }
            }
        } catch {
            logger.error("\(error.localizedDescription)")
            // Unable to start the stream. Set the running state to false.
            isRunning = false
        }
    }
    
    /// Stops capturing screen content.
    func stop() async {
        guard isRunning else { return }
        await captureEngine.stopCapture()
        stopAudioMetering()
        isRunning = false
        
        if let compressionSession {
            VTCompressionSessionInvalidate(compressionSession)
            compressionSession.flush()
            self.compressionSession = nil
        }
        
        keyboardMonitor?.activateMonitor(false)
        guard let circularBuffer else { return }
        let samples: [CMSampleBuffer] = circularBuffer.readAll()
        circularBuffer.finishWriting()
        writeRemaining(samples: samples)
    }
    
    private func startAudioMetering() {
        audioMeterCancellable = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self = self else { return }
            self.audioLevelsProvider.audioLevels = self.captureEngine.audioLevels
        }
    }
    
    private func stopAudioMetering() {
        audioMeterCancellable?.cancel()
        audioLevelsProvider.audioLevels = AudioLevels.zero
    }
    
    /// - Tag: UpdateCaptureConfig
    private func updateEngine() {
        guard isRunning else { return }
        Task {
            let filter = contentFilter
            await captureEngine.update(configuration: streamConfiguration, filter: filter)
            setPickerUpdate(false)
        }
    }

    // MARK: - Content-sharing Picker
    private func initializePickerConfiguration() {
        var initialConfiguration = SCContentSharingPickerConfiguration()
        // Set the allowedPickerModes from the app.
        initialConfiguration.allowedPickerModes = [
            .singleWindow,
            .multipleWindows,
            .singleApplication,
            .multipleApplications,
            .singleDisplay
        ]
        self.allowedPickingModes = initialConfiguration.allowedPickerModes
    }

    private func updatePickerConfiguration() {
        self.screenRecorderPicker.maximumStreamCount = maximumStreamCount
        // Update the default picker configuration to pass to Control Center.
        self.screenRecorderPicker.defaultConfiguration = pickerConfiguration
    }

    /// - Tag: HandlePicker
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        logger.info("Picker canceled for stream \(stream)")
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            logger.info("Picker updated with filter=\(filter) for stream=\(stream)")
            pickerContentFilter = filter
            shouldUsePickerFilter = true
            setPickerUpdate(true)
            updateEngine()
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        logger.error("Error starting picker! \(error)")
    }

    func setPickerUpdate(_ update: Bool) {
        Task { @MainActor in
            self.pickerUpdate = update
        }
    }

    func presentPicker() {
        if let stream = captureEngine.stream {
            SCContentSharingPicker.shared.present(for: stream)
        } else {
            SCContentSharingPicker.shared.present()
        }
    }

    private var pickerConfiguration: SCContentSharingPickerConfiguration {
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = allowedPickingModes
        config.excludedWindowIDs = Array(excludedWindowIDsSelection)
        config.excludedBundleIDs = excludedBundleIDsList
        config.allowsChangingSelectedContent = allowsRepicking
        return config
    }

    /// - Tag: UpdateFilter
    private var contentFilter: SCContentFilter {
        var filter: SCContentFilter
        switch captureType {
        case .display:
            guard let display = selectedDisplay else { fatalError("No display selected.") }
            var excludedApps = [SCRunningApplication]()
            // If a user chooses to exclude the app from the stream,
            // exclude it by matching its bundle identifier.
            if isAppExcluded {
                excludedApps = availableApps.filter { app in
                    Bundle.main.bundleIdentifier == app.bundleIdentifier
                }
            }
            // Create a content filter with excluded apps.
            filter = SCContentFilter(display: display,
                                     excludingApplications: excludedApps,
                                     exceptingWindows: [])
        case .window:
            guard let window = selectedWindow else { fatalError("No window selected.") }
            
            // Create a content filter that includes a single window.
            filter = SCContentFilter(desktopIndependentWindow: window)
        }
        // Use filter from content picker, if active.
        if shouldUsePickerFilter {
            guard let pickerFilter = pickerContentFilter else { return filter }
            filter = pickerFilter
            shouldUsePickerFilter = false
        }
        return filter
    }
    
    private lazy var streamConfiguration: SCStreamConfiguration = {
        
        let streamConfig = SCStreamConfiguration()
        
        // Configure audio capture.
        streamConfig.capturesAudio = isAudioCaptureEnabled
        streamConfig.excludesCurrentProcessAudio = isAppAudioExcluded
        
        // Configure the display content width and height.
        if captureType == .display, let display = selectedDisplay {
            streamConfig.width = display.width * scaleFactor
            streamConfig.height = display.height * scaleFactor
        }
        
        // Configure the window content width and height.
        if captureType == .window, let window = selectedWindow {
            streamConfig.width = Int(window.frame.width) * 2
            streamConfig.height = Int(window.frame.height) * 2
        }
        
        // Set the capture interval at 60 fps.
        streamConfig.minimumFrameInterval = frameInterval
        
        // Increase the depth of the frame queue to ensure high fps at the expense of increasing
        // the memory footprint of WindowServer.
        streamConfig.queueDepth = 5
        
        return streamConfig
    }()
    
    /// - Tag: GetAvailableContent
    private func refreshAvailableContent() async {
        do {
            // Retrieve the available screen content to capture.
            let availableContent = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                        onScreenWindowsOnly: true)
            availableDisplays = availableContent.displays
            
            let windows = filterWindows(availableContent.windows)
            if windows != availableWindows {
                availableWindows = windows
            }
            availableApps = availableContent.applications
            
            if selectedDisplay == nil {
                selectedDisplay = availableDisplays.first
            }
            if selectedWindow == nil {
                selectedWindow = availableWindows.first
            }
        } catch {
            logger.error("Failed to get the shareable content: \(error.localizedDescription)")
        }
    }
    
    private func filterWindows(_ windows: [SCWindow]) -> [SCWindow] {
        windows
        // Sort the windows by app name.
            .sorted { $0.owningApplication?.applicationName ?? "" < $1.owningApplication?.applicationName ?? "" }
        // Remove windows that don't have an associated .app bundle.
            .filter { $0.owningApplication != nil && $0.owningApplication?.applicationName != "" }
        // Remove this app's window from the list.
            .filter { $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
        // Remove tiny windows like status items and such
            .filter { $0.frame.width >= 100 && $0.frame.height >= 100 }
    }
}

extension SCWindow {
    var displayName: String {
        switch (owningApplication, title) {
        case (.some(let application), .some(let title)):
            return "\(application.applicationName): \(title)"
        case (.none, .some(let title)):
            return title
        case (.some(let application), .none):
            return "\(application.applicationName): \(windowID)"
        default:
            return ""
        }
    }
}

extension SCDisplay {
    var displayName: String {
        "Display: \(width) x \(height)"
    }
}

extension ScreenRecorder {
    // MARK: Writing
    
    private func beginWriting(width: Int, height: Int) {
        let directory = FileManager.default.temporaryDirectory
        let fileName = NSUUID().uuidString
        let outputURL = directory.appendingPathComponent(fileName).appendingPathExtension("mov")
        
        assetWriter = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) 
        guard let assetWriter else {    // ^^ <<<  needs to be mov, not mp4 ???
            print("couldn't make AVAssetWriter")
            return
        }
        
        // If you’re appending samples that are already in an acceptable compressed format, pass a value of nil for the output settings to pass
        // the buffers to the output unaltered.
        
        assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        guard let assetWriterInput else { 
            print("no assetWriterInput")
            return
        }
        
        /* "Apps that write media data from a real-time source, such as an instance of AVCaptureOutput, set the input’s expectsMediaDataInRealTime
         property value to true so that the input accurately determines its readiness for more data. When expectsMediaDataInRealTime is true, this
         property value becomes false only when the input can’t process media samples at the current data rate. If this property value becomes 
         false for a real-time source, your app may need to reduce the rate at which it appends samples, or drop them altogether.
         */
        assetWriterInput.expectsMediaDataInRealTime = true
        assetWriter.add(assetWriterInput)
        assetWriter.startWriting()
    }
    
    // Called after each append to sample buffer, but I don't like that since what if it's ALREADY trying to output?
    
    private func writeRemaining(samples: [CMSampleBuffer]) {
        let bufferCount: Int = samples.count
        print("\(#function) with \(samples.count) remaining samples")
       guard bufferCount > 0 else {
            print("\(#function) final buffer is empty already")
            return 
        }
        guard let assetWriterInput else { 
            print("\(#function) no assetWriterInput")
            return 
        }
        // Note: can't reset assetWriterInput.expectsMediaDataInRealTime once it's been set

        var bufferIndex = 0
        let queue = DispatchQueue(label: "audio-write")
        assetWriterInput.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self = self else { return }
            while assetWriterInput.isReadyForMoreMediaData {
                guard bufferIndex < bufferCount else {
                    assetWriterInput.markAsFinished()
                    
                    self.assetWriter!.finishWriting() {      // wait until the writer above to really finish
                        self.circularBuffer = nil
                        self.hasSession = false
                        print("output file: \(self.assetWriter!.outputURL)")
                        NSWorkspace.shared.open(self.assetWriter!.outputURL)
                    }
                    break
                }
                let sampleBuffer: CMSampleBuffer = samples[bufferIndex]
                self.startSessionIfNeeded(sample: sampleBuffer, isRealtime: false)  // If this is the first sample, no need to mark as real-time
                assetWriterInput.append(sampleBuffer)
                bufferIndex += 1
            }
        }
    }
    
    private func startSessionIfNeeded(sample: CMSampleBuffer, isRealtime: Bool) {
        guard !self.hasSession, let assetWriter, let assetWriterInput else { return }
        
        // Only set this to true now, since we didn't need to deal with real-time writing until the session is first started
        if isRealtime {
            assetWriterInput.expectsMediaDataInRealTime = true
        }
        
        // the presentation timestamp (CMTime: "Rational time value") of the sample that will be presented first
        assetWriter.startSession(atSourceTime: sample.presentationTimeStamp)
        print("\(#function) at \(sample.presentationTime)")
        self.hasSession = true
    }
    
    // Same as writeToFile but with CMSampleBuffer.
    
    private func writeToFile(sampleBuffer: CMSampleBuffer) {
        print("\(#function)")
        self.startSessionIfNeeded(sample: sampleBuffer, isRealtime: true)   // If this is first session, this is real-time writing
        if assetWriterInput!.isReadyForMoreMediaData {
            assetWriterInput!.append(sampleBuffer)
        } else {
            print("🧛 Skipping frame because input is not ready - should not be happening with real-time!")
        }
    }
  
    
    // NOT USED, but maybe we want it for directly writing to the file.
    // this is where we feed the frames to AVAssetWriter which will save out the video to a file
    private func writeToFile(frame: CapturedFrame) {
        // print("\(#function)")
        if !hasSession {
            
            // the presentation timestamp (CMTime: "Rational time value") of the sample that will be presented first
            let timestamp: CMTime = frame.sampleBuffer.presentationTimeStamp
            assetWriter!.startSession(atSourceTime: timestamp)
            hasSession = true
        }
        
        // TODO: update it to wait to be ready, rather than dropping frames?
        
        if assetWriterInput!.isReadyForMoreMediaData {
            assetWriterInput!.append(frame.sampleBuffer)
        } else {
            print("🧛 Skipping frame because input is not ready - should not be happening with real-time!")
        }
    }
}

extension VTCompressionSession {
    func flush(untilPresentationTimeStamp: CMTime = .invalid) {
        VTCompressionSessionCompleteFrames(self, untilPresentationTimeStamp: untilPresentationTimeStamp)
    }
}

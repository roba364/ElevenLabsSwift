import AVFoundation
import Combine
import DeviceKit
import Foundation
import os.log

/// Main class for ElevenLabsSwift package
public class ElevenLabsSDK {
    public static let version = "1.1.3"

    private enum Constants {
        static let defaultApiOrigin = "wss://api.elevenlabs.io"
        static let defaultApiPathname = "/v1/convai/conversation?agent_id="
        static let inputSampleRate: Double = 16000
        static let sampleRate: Double = 16000
        static let ioBufferDuration: Double = 0.005
        static let volumeUpdateInterval: TimeInterval = 0.1
        static let fadeOutDuration: TimeInterval = 2.0
        static let bufferSize: AVAudioFrameCount = 1024

        // WebSocket message size limits
        static let maxWebSocketMessageSize = 1024 * 1024 // 1MB WebSocket limit
        static let safeMessageSize = 750 * 1024 // 750KB - safely under the limit
        static let maxRequestedMessageSize = 8 * 1024 * 1024 // 8MB - request larger buffer if available
    }

    // MARK: - Session Config Utilities

    public enum Language: String, Codable, Sendable {
        case en, ja, zh, de, hi, fr, ko, pt, it, es, id, nl, tr, pl, sv, bg, ro, ar, cs, el, fi, ms, da, ta, uk, ru, hu, no, vi
    }

    public struct AgentPrompt: Codable, Sendable {
        public var prompt: String?

        public init(prompt: String? = nil) {
            self.prompt = prompt
        }
    }

    public struct TTSConfig: Codable, Sendable {
        public var voiceId: String?

        private enum CodingKeys: String, CodingKey {
            case voiceId = "voice_id"
        }

        public init(voiceId: String? = nil) {
            self.voiceId = voiceId
        }
    }

    public struct ConversationConfigOverride: Codable, Sendable {
        public var agent: AgentConfig?
        public var tts: TTSConfig?

        public init(agent: AgentConfig? = nil, tts: TTSConfig? = nil) {
            self.agent = agent
            self.tts = tts
        }
    }

    public struct AgentConfig: Codable, Sendable {
        public var prompt: AgentPrompt?
        public var firstMessage: String?
        public var language: Language?

        private enum CodingKeys: String, CodingKey {
            case prompt
            case firstMessage = "first_message"
            case language
        }

        public init(prompt: AgentPrompt? = nil, firstMessage: String? = nil, language: Language? = nil) {
            self.prompt = prompt
            self.firstMessage = firstMessage
            self.language = language
        }
    }

    public enum LlmExtraBodyValue: Codable, Sendable {
        case string(String)
        case number(Double)
        case boolean(Bool)
        case null
        case array([LlmExtraBodyValue])
        case dictionary([String: LlmExtraBodyValue])

        var jsonValue: Any {
            switch self {
            case let .string(str): return str
            case let .number(num): return num
            case let .boolean(bool): return bool
            case .null: return NSNull()
            case let .array(arr): return arr.map { $0.jsonValue }
            case let .dictionary(dict): return dict.mapValues { $0.jsonValue }
            }
        }
    }

    // MARK: - Audio Utilities

    public static func arrayBufferToBase64(_ data: Data) -> String {
        data.base64EncodedString()
    }

    public static func base64ToArrayBuffer(_ base64: String) -> Data? {
        Data(base64Encoded: base64)
    }

    // MARK: - Client Tools

    public typealias ClientToolHandler = @Sendable (Parameters) async throws -> String?

    public typealias Parameters = [String: Any]

    public struct ClientTools: Sendable {
        private var tools: [String: ClientToolHandler] = [:]
        private let lock = NSLock() // Ensure thread safety

        public init() {}

        public mutating func register(_ name: String, handler: @escaping @Sendable ClientToolHandler) {
            lock.withLock {
                tools[name] = handler
            }
        }

        public func handle(_ name: String, parameters: Parameters) async throws -> String? {
            let handler: ClientToolHandler? = lock.withLock { tools[name] }
            guard let handler = handler else {
                throw ClientToolError.handlerNotFound(name)
            }
            return try await handler(parameters)
        }
    }

    public enum ClientToolError: Error {
        case handlerNotFound(String)
        case invalidParameters
        case executionFailed(String)
    }

    // MARK: - Audio Processing

    public class AudioConcatProcessor {
        private var buffers: [Data] = []
        private var cursor: Int = 0
        private var currentBuffer: Data?
        private var wasInterrupted: Bool = false
        private var finished: Bool = false
        public var onProcess: ((Bool) -> Void)?

        public func process(outputs: inout [[Float]]) {
            var isFinished = false
            let outputChannel = 0
            var outputBuffer = outputs[outputChannel]
            var outputIndex = 0

            while outputIndex < outputBuffer.count {
                if currentBuffer == nil {
                    if buffers.isEmpty {
                        isFinished = true
                        break
                    }
                    currentBuffer = buffers.removeFirst()
                    cursor = 0
                }

                if let currentBuffer = currentBuffer {
                    let remainingSamples = currentBuffer.count / 2 - cursor
                    let samplesToWrite = min(remainingSamples, outputBuffer.count - outputIndex)

                    guard let int16ChannelData = currentBuffer.withUnsafeBytes({ $0.bindMemory(to: Int16.self).baseAddress }) else {
                        print("Failed to access Int16 channel data.")
                        break
                    }

                    for sampleIndex in 0 ..< samplesToWrite {
                        let sample = int16ChannelData[cursor + sampleIndex]
                        outputBuffer[outputIndex] = Float(sample) / 32768.0
                        outputIndex += 1
                    }

                    cursor += samplesToWrite

                    if cursor >= currentBuffer.count / 2 {
                        self.currentBuffer = nil
                    }
                }
            }

            outputs[outputChannel] = outputBuffer

            if finished != isFinished {
                finished = isFinished
                onProcess?(isFinished)
            }
        }

        public func handleMessage(_ message: [String: Any]) {
            guard let type = message["type"] as? String else { return }

            switch type {
            case "buffer":
                if let buffer = message["buffer"] as? Data {
                    wasInterrupted = false
                    buffers.append(buffer)
                }
            case "interrupt":
                wasInterrupted = true
            case "clearInterrupted":
                if wasInterrupted {
                    wasInterrupted = false
                    buffers.removeAll()
                    currentBuffer = nil
                }
            default:
                break
            }
        }
    }

    // MARK: - Device Check

    /// Checks if the current device is likely an iPhone 13 or older model using DeviceKit.
    private static func isOlderDeviceModel_DeviceKit() -> Bool {
        let currentDevice = Device.current
        let logger = Logger(subsystem: "com.elevenlabs.ElevenLabsSDK", category: "DeviceCheck")

        // Define the array of older iPhone models (up to iPhone 13 series)
        // Note: This array might need updates if DeviceKit adds more specific older models or you need to support very old ones.
        let olderModels: [Device] = [
            // iPhone 13 Series
            .iPhone13, .iPhone13Mini, .iPhone13Pro, .iPhone13ProMax,
            // iPhone SE Series (relevant generations)
            .iPhoneSE2, .iPhoneSE3, // Assuming SE 2/3 fall under 'older'
            // iPhone 12 Series
            .iPhone12, .iPhone12Mini, .iPhone12Pro, .iPhone12ProMax,
            // iPhone 11 Series
            .iPhone11, .iPhone11Pro, .iPhone11ProMax,
            // iPhone X Series
            .iPhoneX, .iPhoneXR, .iPhoneXS, .iPhoneXSMax,
            // iPhone 8 Series
            .iPhone8, .iPhone8Plus,
            // iPhone 7 Series
            .iPhone7, .iPhone7Plus,
            // Older SE
            .iPhoneSE,
            // Add older models here if needed (e.g., .iPhone6s, .iPhone6sPlus, etc.)
        ]

        if currentDevice.isPhone && olderModels.contains(currentDevice) {
            logger.debug("DeviceKit check: Detected older iPhone model (\(currentDevice.description)). Applying workaround.")
            return true
        }

        // Covers iPhone 14 series and newer, iPads, iPods, Simulators, unknown devices.
        logger.debug("DeviceKit check: Detected newer iPhone model (\(currentDevice.description)) or non-applicable device. No workaround needed.")
        return false
    }

    // MARK: - Connection

    public enum DynamicVariableValue: Sendable {
        case string(String)
        case number(Double)
        case boolean(Bool)
        case int(Int)

        var jsonValue: Any {
            switch self {
            case let .string(str): return str
            case let .number(num): return num
            case let .boolean(bool): return bool
            case let .int(int): return int
            }
        }
    }

    public struct SessionConfig: Sendable {
        public let signedUrl: String?
        public let agentId: String?
        public let overrides: ConversationConfigOverride?
        public let customLlmExtraBody: [String: LlmExtraBodyValue]?
        public let dynamicVariables: [String: DynamicVariableValue]?

        public init(signedUrl: String, overrides: ConversationConfigOverride? = nil, customLlmExtraBody: [String: LlmExtraBodyValue]? = nil, clientTools _: ClientTools = ClientTools(), dynamicVariables: [String: DynamicVariableValue]? = nil) {
            self.signedUrl = signedUrl
            agentId = nil
            self.overrides = overrides
            self.customLlmExtraBody = customLlmExtraBody
            self.dynamicVariables = dynamicVariables
        }

        public init(agentId: String, overrides: ConversationConfigOverride? = nil, customLlmExtraBody: [String: LlmExtraBodyValue]? = nil, clientTools _: ClientTools = ClientTools(), dynamicVariables: [String: DynamicVariableValue]? = nil) {
            self.agentId = agentId
            signedUrl = nil
            self.overrides = overrides
            self.customLlmExtraBody = customLlmExtraBody
            self.dynamicVariables = dynamicVariables
        }
    }

    public class Connection: @unchecked Sendable {
        public let socket: URLSessionWebSocketTask
        public let conversationId: String
        public let sampleRate: Int

        private init(socket: URLSessionWebSocketTask, conversationId: String, sampleRate: Int) {
            self.socket = socket
            self.conversationId = conversationId
            self.sampleRate = sampleRate
        }

        public static func create(config: SessionConfig) async throws -> Connection {
            let origin = ProcessInfo.processInfo.environment["ELEVENLABS_CONVAI_SERVER_ORIGIN"] ?? Constants.defaultApiOrigin
            let pathname = ProcessInfo.processInfo.environment["ELEVENLABS_CONVAI_SERVER_PATHNAME"] ?? Constants.defaultApiPathname

            let urlString: String
            if let signedUrl = config.signedUrl {
                urlString = signedUrl
            } else if let agentId = config.agentId {
                urlString = "\(origin)\(pathname)\(agentId)"
            } else {
                throw ElevenLabsError.invalidConfiguration
            }

            guard let url = URL(string: urlString) else {
                throw ElevenLabsError.invalidURL
            }

            let session = URLSession(configuration: .default)
            let socket = session.webSocketTask(with: url)
            socket.resume()

            // Always send initialization event
            var initEvent: [String: Any] = ["type": "conversation_initiation_client_data"]

            // Add overrides if present
            if let overrides = config.overrides,
               let overridesDict = overrides.dictionary
            {
                initEvent["conversation_config_override"] = overridesDict
            }

            // Add custom body if present
            if let customBody = config.customLlmExtraBody {
                initEvent["custom_llm_extra_body"] = customBody.mapValues { $0.jsonValue }
            }

            // Add dynamic variables if present - Convert to JSON-compatible values
            if let dynamicVars = config.dynamicVariables {
                initEvent["dynamic_variables"] = dynamicVars.mapValues { $0.jsonValue }
            }

            let jsonData = try JSONSerialization.data(withJSONObject: initEvent)
            let jsonString = String(data: jsonData, encoding: .utf8)!
            try await socket.send(.string(jsonString))

            let configData = try await receiveInitialMessage(socket: socket)
            return Connection(socket: socket, conversationId: configData.conversationId, sampleRate: configData.sampleRate)
        }

        private static func receiveInitialMessage(
            socket: URLSessionWebSocketTask
        ) async throws -> (conversationId: String, sampleRate: Int) {
            return try await withCheckedThrowingContinuation { continuation in
                socket.receive { result in
                    switch result {
                    case let .success(message):
                        switch message {
                        case let .string(text):
                            guard let data = text.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                                  let type = json["type"] as? String,
                                  type == "conversation_initiation_metadata",
                                  let metadata = json["conversation_initiation_metadata_event"] as? [String: Any],
                                  let conversationId = metadata["conversation_id"] as? String,
                                  let audioFormat = metadata["agent_output_audio_format"] as? String
                            else {
                                continuation.resume(throwing: ElevenLabsError.invalidInitialMessageFormat)
                                return
                            }

                            let sampleRate = Int(audioFormat.replacingOccurrences(of: "pcm_", with: "")) ?? 16000
                            continuation.resume(returning: (conversationId: conversationId, sampleRate: sampleRate))

                        case .data:
                            continuation.resume(throwing: ElevenLabsError.unexpectedBinaryMessage)

                        @unknown default:
                            continuation.resume(throwing: ElevenLabsError.unknownMessageType)
                        }
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        public func close() {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    // MARK: - Audio Input

    public class Input {
        public let audioUnit: AudioUnit
        public var audioFormat: AudioStreamBasicDescription
        public var isRecording: Bool = false
        private var recordCallback: ((AVAudioPCMBuffer, Float) -> Void)?
        private var currentAudioLevel: Float = 0.0

        private init(audioUnit: AudioUnit, audioFormat: AudioStreamBasicDescription) {
            self.audioUnit = audioUnit
            self.audioFormat = audioFormat
        }

        public static func create(sampleRate: Double) async throws -> Input {
            // Define the Audio Component
            var audioComponentDesc = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_VoiceProcessingIO, // For echo cancellation
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )

            guard let audioComponent = AudioComponentFindNext(nil, &audioComponentDesc) else {
                throw ElevenLabsError.failedToCreateAudioComponent
            }

            var audioUnitOptional: AudioUnit?
            AudioComponentInstanceNew(audioComponent, &audioUnitOptional)
            guard let audioUnit = audioUnitOptional else {
                throw ElevenLabsError.failedToCreateAudioComponentInstance
            }

            // Create the Input instance
            let input = Input(audioUnit: audioUnit, audioFormat: AudioStreamBasicDescription())

            // Enable IO for recording
            var enableIO: UInt32 = 1
            AudioUnitSetProperty(audioUnit,
                                 kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input,
                                 1,
                                 &enableIO,
                                 UInt32(MemoryLayout.size(ofValue: enableIO)))

            // Disable output
            var disableIO: UInt32 = 0
            AudioUnitSetProperty(audioUnit,
                                 kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Output,
                                 0,
                                 &disableIO,
                                 UInt32(MemoryLayout.size(ofValue: disableIO)))

            // Set the audio format
            var audioFormat = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 2,
                mFramesPerPacket: 1,
                mBytesPerFrame: 2,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 16,
                mReserved: 0
            )

            AudioUnitSetProperty(audioUnit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output,
                                 1, // Bus 1 (Output scope of input element)
                                 &audioFormat,
                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

            input.audioFormat = audioFormat

            // Set the input callback
            var inputCallbackStruct = AURenderCallbackStruct(
                inputProc: inputRenderCallback,
                inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(input).toOpaque())
            )
            AudioUnitSetProperty(audioUnit,
                                 kAudioOutputUnitProperty_SetInputCallback,
                                 kAudioUnitScope_Global,
                                 1, // Bus 1
                                 &inputCallbackStruct,
                                 UInt32(MemoryLayout<AURenderCallbackStruct>.size))

            // Initialize and start the audio unit
            AudioUnitInitialize(audioUnit)
            AudioOutputUnitStart(audioUnit)

            return input
        }

        public func setRecordCallback(_ callback: @escaping (AVAudioPCMBuffer, Float) -> Void) {
            recordCallback = callback
        }

        public func close() {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }

        private static let inputRenderCallback: AURenderCallback = {
            inRefCon,
                ioActionFlags,
                inTimeStamp,
                _,
                inNumberFrames,
                _
                -> OSStatus in
            let input = Unmanaged<Input>.fromOpaque(inRefCon).takeUnretainedValue()
            let audioUnit = input.audioUnit

            let byteSize = Int(inNumberFrames) * MemoryLayout<Int16>.size
            let data = UnsafeMutableRawPointer.allocate(byteCount: byteSize, alignment: MemoryLayout<Int16>.alignment)
            var audioBuffer = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(byteSize),
                mData: data
            )
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: audioBuffer
            )

            let status = AudioUnitRender(audioUnit,
                                         ioActionFlags,
                                         inTimeStamp,
                                         1, // inBusNumber
                                         inNumberFrames,
                                         &bufferList)

            if status == noErr {
                let frameCount = Int(inNumberFrames)
                guard let audioFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: input.audioFormat.mSampleRate,
                    channels: 1,
                    interleaved: true
                ) else {
                    data.deallocate()
                    return noErr
                }
                guard let pcmBuffer = AVAudioPCMBuffer(
                    pcmFormat: audioFormat,
                    frameCapacity: AVAudioFrameCount(frameCount)
                ) else {
                    data.deallocate()
                    return noErr
                }
                pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
                let dataPointer = data.assumingMemoryBound(to: Int16.self)
                if let channelData = pcmBuffer.int16ChannelData {
                    memcpy(channelData[0], dataPointer, byteSize)
                }

                // Compute RMS value for volume level
                var rms: Float = 0.0
                for i in 0 ..< frameCount {
                    let sample = Float(dataPointer[i]) / Float(Int16.max)
                    rms += sample * sample
                }
                rms = sqrt(rms / Float(frameCount))

                // Call the callback with the audio buffer and current audio level
                input.recordCallback?(pcmBuffer, rms)
            }

            data.deallocate()
            return status
        }
    }

    // MARK: - Output

    public class Output {
        public let engine: AVAudioEngine
        public let playerNode: AVAudioPlayerNode
        public let mixer: AVAudioMixerNode
        let audioQueue: DispatchQueue
        let audioFormat: AVAudioFormat

        private init(engine: AVAudioEngine, playerNode: AVAudioPlayerNode, mixer: AVAudioMixerNode, audioFormat: AVAudioFormat) {
            self.engine = engine
            self.playerNode = playerNode
            self.mixer = mixer
            self.audioFormat = audioFormat
            audioQueue = DispatchQueue(label: "com.elevenlabs.audioQueue", qos: .userInteractive)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleInterruption),
                name: .AVAudioEngineConfigurationChange,
                object: engine
            )
        }

        public static func create(sampleRate: Double) async throws -> Output {
            let engine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()
            let mixer = AVAudioMixerNode()

            engine.attach(playerNode)
            engine.attach(mixer)

            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
                throw ElevenLabsError.failedToCreateAudioFormat
            }
            engine.connect(playerNode, to: mixer, format: format)
            engine.connect(mixer, to: engine.mainMixerNode, format: format)

            return Output(engine: engine, playerNode: playerNode, mixer: mixer, audioFormat: format)
        }

        public func close() {
            engine.stop()
            // see AVAudioEngine documentation
            playerNode.stop()
        }

        public func startPlaying() throws {
            try engine.start()
            playerNode.play()
        }

        @objc private func handleInterruption() throws {
            engine.connect(playerNode, to: mixer, format: audioFormat)
            engine.connect(mixer, to: engine.mainMixerNode, format: audioFormat)
            try startPlaying()
        }
    }

    // MARK: - Conversation

    public enum Role: String {
        case user
        case ai
    }

    public enum Mode: String {
        case speaking
        case listening
    }

    public enum Status: String {
        case connecting
        case connected
        case disconnecting
        case disconnected
    }

    public struct Callbacks: Sendable {
        public var onConnect: @Sendable (String) -> Void = { _ in }
        public var onDisconnect: @Sendable () -> Void = {}
        public var onMessage: @Sendable (String, Role) -> Void = { _, _ in }
        public var onError: @Sendable (String, Any?) -> Void = { _, _ in }
        public var onStatusChange: @Sendable (Status) -> Void = { _ in }
        public var onModeChange: @Sendable (Mode) -> Void = { _ in }
        public var onVolumeUpdate: @Sendable (Float) -> Void = { _ in }

        /// A callback that informs about a message correction.
        /// - Parameters:
        ///   - original: The original message. (Type: `String`)
        ///   - corrected: The corrected message. (Type: `String`)
        ///   - role: The role associated with the correction. (Type: `Role`)
        public var onMessageCorrection: @Sendable (String, String, Role) -> Void = { _, _, _ in }

        // НОВЫЕ CALLBACK'И ДЛЯ AUDIO EVENTS
        /// Вызывается когда начинается воспроизведение аудио от агента
        /// - Parameter eventId: ID события аудио
        public var onAudioPlaybackStart: @Sendable (Int) -> Void = { _ in }

        /// Вызывается когда заканчивается воспроизведение аудио от агента
        public var onAudioPlaybackEnd: @Sendable () -> Void = {}

        /// Вызывается для каждого аудио чанка (опционально, для детального трекинга)
        /// - Parameters:
        ///   - eventId: ID события
        ///   - chunkSize: размер чанка в байтах
        public var onAudioChunkReceived: @Sendable (Int, Int) -> Void = { _, _ in }

        public init() {}
    }

    public class Conversation: @unchecked Sendable {
        private let connection: Connection
        private let input: Input
        private let output: Output
        private let callbacks: Callbacks
        private let clientTools: ClientTools?

        private let modeLock = NSLock()
        private let statusLock = NSLock()
        private let volumeLock = NSLock()
        private let lastInterruptTimestampLock = NSLock()
        private let isProcessingInputLock = NSLock()

        private var inputVolumeUpdateTimer: Timer?
        private let inputVolumeUpdateInterval: TimeInterval = 0.1 // Update every 100ms
        private var currentInputVolume: Float = 0.0

        private var _mode: Mode = .listening
        private var _status: Status = .connecting
        private var _volume: Float = 1.0
        private var _lastInterruptTimestamp: Int = 0
        private var _isProcessingInput: Bool = true

        private var mode: Mode {
            get { modeLock.withLock { _mode } }
            set { modeLock.withLock { _mode = newValue } }
        }

        private var status: Status {
            get { statusLock.withLock { _status } }
            set { statusLock.withLock { _status = newValue } }
        }

        private var volume: Float {
            get { volumeLock.withLock { _volume } }
            set { volumeLock.withLock { _volume = newValue } }
        }

        private var lastInterruptTimestamp: Int {
            get { lastInterruptTimestampLock.withLock { _lastInterruptTimestamp } }
            set { lastInterruptTimestampLock.withLock { _lastInterruptTimestamp = newValue } }
        }

        private var isProcessingInput: Bool {
            get { isProcessingInputLock.withLock { _isProcessingInput } }
            set { isProcessingInputLock.withLock { _isProcessingInput = newValue } }
        }

        private var audioBuffers: [AVAudioPCMBuffer] = []
        private let audioBufferLock = NSLock()

        private var previousSamples: [Int16] = Array(repeating: 0, count: 10)
        private var isFirstBuffer = true

        private let audioConcatProcessor = ElevenLabsSDK.AudioConcatProcessor()
        private var outputBuffers: [[Float]] = [[]]

        private let logger = Logger(subsystem: "com.elevenlabs.ElevenLabsSDK", category: "Conversation")

        // Новые свойства для отслеживания состояния аудио
        private var isAudioPlaying: Bool = false
        private var isAudioPlayingLock = NSLock()
        private var currentAudioEventId: Int?

        private var audioPlaying: Bool {
            get { isAudioPlayingLock.withLock { isAudioPlaying } }
            set { isAudioPlayingLock.withLock { isAudioPlaying = newValue } }
        }

        private func setupInputVolumeMonitoring() {
            DispatchQueue.main.async {
                self.inputVolumeUpdateTimer = Timer.scheduledTimer(withTimeInterval: self.inputVolumeUpdateInterval, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.callbacks.onVolumeUpdate(self.currentInputVolume)
                }
            }
        }

        private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
            guard let channelData = buffer.floatChannelData else {
                return
            }

            var sumOfSquares: Float = 0
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength) // Convert to Int

            for channel in 0 ..< channelCount {
                let data = channelData[channel]
                for i in 0 ..< frameLength {
                    sumOfSquares += data[i] * data[i]
                }
            }

            let rms = sqrt(sumOfSquares / Float(frameLength * channelCount))
            let meterLevel = rms > 0 ? 20 * log10(rms) : -50.0 // Safeguarded

            // Normalize the meter level to a 0-1 range
            let normalizedLevel = max(0, min(1, (meterLevel + 50) / 50))

            // Call the callback with the volume level
            DispatchQueue.main.async {
                self.callbacks.onVolumeUpdate(normalizedLevel)
            }
        }

        private init(connection: Connection, input: Input, output: Output, callbacks: Callbacks, clientTools: ClientTools?) {
            self.connection = connection
            self.input = input
            self.output = output
            self.callbacks = callbacks
            self.clientTools = clientTools

            // ОБНОВЛЕННЫЙ onProcess callback
            audioConcatProcessor.onProcess = { [weak self] finished in
                guard let self = self else { return }
                if finished {
                    // ОТСЛЕЖИВАНИЕ КОНЦА ВОСПРОИЗВЕДЕНИЯ
                    if self.audioPlaying {
                        self.audioPlaying = false
                        self.logger.info("Audio playback ended")
                        self.callbacks.onAudioPlaybackEnd()
                    }
                    self.updateMode(.listening)
                }
            }

            setupWebSocket()
            setupAudioProcessing()
            setupInputVolumeMonitoring()
        }

        /// Starts a new conversation session
        /// - Parameters:
        ///   - config: Session configuration
        ///   - callbacks: Callbacks for conversation events
        ///   - clientTools: Client tools callbacks (optional)
        /// - Returns: A started `Conversation` instance
        public static func startSession(config: SessionConfig, callbacks: Callbacks = Callbacks(), clientTools: ClientTools? = nil) async throws -> Conversation {
            // Step 1: Configure the audio session
            try ElevenLabsSDK.configureAudioSession()

            // Step 2: Create the WebSocket connection
            let connection = try await Connection.create(config: config)

            // Step 3: Create the audio input
            let input = try await Input.create(sampleRate: Constants.inputSampleRate)

            // Step 4: Create the audio output
            let output = try await Output.create(sampleRate: Double(connection.sampleRate))

            // Step 5: Initialize the Conversation
            let conversation = Conversation(connection: connection, input: input, output: output, callbacks: callbacks, clientTools: clientTools)

            // Step 6: Start playing audio (implicitly activates session and engine)
            try output.startPlaying()
            conversation.logger.info("Audio engine started.")

            // Step 6.5: Apply speaker output override for older devices
            if isOlderDeviceModel_DeviceKit() { // Use the new DeviceKit-based check
                conversation.logger.info("Applying speaker override for older device model.")
                // Dispatch after a short delay to ensure session/engine are fully ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { // 0.5s delay, adjust if needed
                    do {
                        try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
                        conversation.logger.info("Successfully overridden output audio port to speaker.")
                    } catch {
                        conversation.logger.error("Failed to override output audio port to speaker: \(error.localizedDescription)")
                        // Optionally trigger onError callback
                        // conversation.callbacks.onError("Failed to set speaker output", error)
                    }
                }
            } else {
                conversation.logger.info("Speaker override not needed for this device model.")
            }

            // Step 7: Start recording
            conversation.startRecording()

            return conversation
        }

        private func setupWebSocket() {
            callbacks.onConnect(connection.conversationId)
            updateStatus(.connected)

            // Configure WebSocket for larger messages if possible
            if let urlSessionTask = connection.socket as? URLSessionWebSocketTask {
                if #available(iOS 15.0, macOS 12.0, *) {
                    urlSessionTask.maximumMessageSize = Constants.maxRequestedMessageSize
                }
            }

            receiveMessages()
        }

        private func receiveMessages() {
            connection.socket.receive { [weak self] result in
                guard let self = self else { return }

                switch result {
                case let .success(message):
                    self.handleWebSocketMessage(message)
                case let .failure(error):
                    self.logger.error("WebSocket error: \(error.localizedDescription)")
                    self.callbacks.onError("WebSocket error", error)
                    self.endSession()
                }

                if self.status == .connected {
                    self.receiveMessages()
                }
            }
        }

        public var conversationVolume: Float {
            get {
                return volume
            }
            set {
                volume = newValue
                output.mixer.volume = newValue
            }
        }

        private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
            switch message {
            case let .string(text):
                guard let data = text.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let type = json["type"] as? String
                else {
                    callbacks.onError("Invalid message format", nil)
                    return
                }

                print("---> type: \(type)")

                switch type {
                case "client_tool_call":
                    handleClientToolCall(json)

                case "interruption":
                    handleInterruptionEvent(json)

                case "agent_response":
                    handleAgentResponseEvent(json)

                case "agent_response_correction":
                    handleAgentResponseCorrectionEvent(json)

                case "user_transcript":
                    handleUserTranscriptEvent(json)

                case "audio":
                    handleAudioEvent(json)

                case "ping":
                    handlePingEvent(json)

                case "internal_tentative_agent_response":
                    break

                case "internal_vad_score":
                    break

                case "internal_turn_probability":
                    break

                default:
                    callbacks.onError("Unknown message type", json)
                }

            case .data:
                callbacks.onError("Received unexpected binary message", nil)

            @unknown default:
                callbacks.onError("Received unknown message type", nil)
            }
        }

        private func handleClientToolCall(_ json: [String: Any]) {
            guard let toolCall = json["client_tool_call"] as? [String: Any],
                  let toolName = toolCall["tool_name"] as? String,
                  let toolCallId = toolCall["tool_call_id"] as? String,
                  let parameters = toolCall["parameters"] as? [String: Any]
            else {
                callbacks.onError("Invalid client tool call format", json)
                return
            }

            // Serialize parameters to JSON Data for thread-safety
            let serializedParameters: Data
            do {
                serializedParameters = try JSONSerialization.data(withJSONObject: parameters, options: [])
            } catch {
                callbacks.onError("Failed to serialize parameters", error)
                return
            }

            // Execute in a Task (now safe because of serializedParameters)
            Task { [toolName, toolCallId, serializedParameters] in
                do {
                    // Deserialize within the Task to pass into clientTools.handle
                    let deserializedParameters = try JSONSerialization.jsonObject(with: serializedParameters) as? [String: Any] ?? [:]

                    let result = try await clientTools?.handle(toolName, parameters: deserializedParameters)

                    let response: [String: Any] = [
                        "type": "client_tool_result",
                        "tool_call_id": toolCallId,
                        "result": result ?? "",
                        "is_error": false,
                    ]
                    sendWebSocketMessage(response)
                } catch {
                    let response: [String: Any] = [
                        "type": "client_tool_result",
                        "tool_call_id": toolCallId,
                        "result": error.localizedDescription,
                        "is_error": true,
                    ]
                    sendWebSocketMessage(response)
                }
            }
        }

        private func handleInterruptionEvent(_ json: [String: Any]) {
            guard let event = json["interruption_event"] as? [String: Any],
                  let eventId = event["event_id"] as? Int else { return }

            lastInterruptTimestamp = eventId

            // УВЕДОМЛЕНИЕ О ПРИНУДИТЕЛЬНОМ ЗАВЕРШЕНИИ АУДИО
            if audioPlaying {
                audioPlaying = false
                logger.info("Audio playback interrupted by event ID: \(eventId)")
                callbacks.onAudioPlaybackEnd() // Уведомляем о завершении даже при прерывании
            }

            fadeOutAudio()
            clearAudioBuffers()
            stopPlayback()
        }

        private func handleAgentResponseEvent(_ json: [String: Any]) {
            guard let event = json["agent_response_event"] as? [String: Any],
                  let response = event["agent_response"] as? String else { return }
            callbacks.onMessage(response, .ai)
        }

        private func handleAgentResponseCorrectionEvent(_ json: [String: Any]) {
            guard let event = json["agent_response_correction_event"] as? [String: Any],
                  let original_response = event["original_agent_response"] as? String,
                  let corrected_response = event["corrected_agent_response"] as? String else { return }
            callbacks.onMessageCorrection(original_response, corrected_response, .ai)
        }

        private func handleUserTranscriptEvent(_ json: [String: Any]) {
            guard let event = json["user_transcription_event"] as? [String: Any],
                  let transcript = event["user_transcript"] as? String else { return }
            callbacks.onMessage(transcript, .user)
        }

        private func handleAudioEvent(_ json: [String: Any]) {
            guard let event = json["audio_event"] as? [String: Any],
                  let audioBase64 = event["audio_base_64"] as? String,
                  let eventId = event["event_id"] as? Int,
                  lastInterruptTimestamp <= eventId else { return }

            // ОТСЛЕЖИВАНИЕ НАЧАЛА ВОСПРОИЗВЕДЕНИЯ
            if !audioPlaying {
                audioPlaying = true
                currentAudioEventId = eventId
                logger.info("Audio playback started with event ID: \(eventId)")
                callbacks.onAudioPlaybackStart(eventId)
            }

            // Вычисляем размер чанка для callback'а
            let chunkSizeBytes = (audioBase64.utf8.count * 3) / 4 // приблизительный размер после декодирования base64
            callbacks.onAudioChunkReceived(eventId, chunkSizeBytes)

            // Check if we need to split the audio chunk for WebSocket size limits
            if audioBase64.utf8.count > Constants.maxWebSocketMessageSize {
                // Split the base64 string into multiple parts to process separately
                let chunkSize = Constants.safeMessageSize
                var offset = 0

                while offset < audioBase64.count {
                    let endIndex = min(offset + chunkSize, audioBase64.count)
                    let startIndex = audioBase64.index(audioBase64.startIndex, offsetBy: offset)
                    let endStringIndex = audioBase64.index(audioBase64.startIndex, offsetBy: endIndex)
                    let subChunk = String(audioBase64[startIndex..<endStringIndex])

                    addAudioBase64Chunk(subChunk)
                    offset = endIndex
                }
            } else {
                // Process the whole chunk
                addAudioBase64Chunk(audioBase64)
            }

            updateMode(.speaking)
        }

        private func handlePingEvent(_ json: [String: Any]) {
            guard let event = json["ping_event"] as? [String: Any],
                  let eventId = event["event_id"] as? Int else { return }
            let response: [String: Any] = ["type": "pong", "event_id": eventId]
            sendWebSocketMessage(response)
        }

        private func sendWebSocketMessage(_ message: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  let string = String(data: data, encoding: .utf8)
            else {
                callbacks.onError("Failed to encode message", message)
                return
            }

            connection.socket.send(.string(string)) { [weak self] error in
                if let error = error {
                    self?.logger.error("Failed to send WebSocket message: \(error.localizedDescription)")
                    self?.callbacks.onError("Failed to send WebSocket message", error)
                }
            }
        }

        private func setupAudioProcessing() {
            input.setRecordCallback { [weak self] buffer, rms in
                guard let self = self, self.isProcessingInput else { return }

                // Convert buffer data to base64 string
                if let int16ChannelData = buffer.int16ChannelData {
                    let frameLength = Int(buffer.frameLength)
                    let totalBytes = frameLength * MemoryLayout<Int16>.size

                    // If buffer is small enough, send in one chunk
                    if totalBytes <= Constants.safeMessageSize {
                        let data = Data(bytes: int16ChannelData[0], count: totalBytes)
                        let base64String = data.base64EncodedString()
                        let message: [String: Any] = ["type": "user_audio_chunk", "user_audio_chunk": base64String]
                        self.sendWebSocketMessage(message)
                    } else {
                        // Split into smaller chunks
                        let framesPerChunk = Constants.safeMessageSize / MemoryLayout<Int16>.size
                        var frameOffset = 0

                        while frameOffset < frameLength {
                            let framesInChunk = min(framesPerChunk, frameLength - frameOffset)
                            let bytesInChunk = framesInChunk * MemoryLayout<Int16>.size

                            let chunkData = Data(bytes: int16ChannelData[0].advanced(by: frameOffset), count: bytesInChunk)
                            let base64String = chunkData.base64EncodedString()

                            let message: [String: Any] = ["type": "user_audio_chunk", "user_audio_chunk": base64String]
                            self.sendWebSocketMessage(message)

                            frameOffset += framesInChunk
                        }
                    }
                } else {
                    self.logger.error("Failed to get int16 channel data")
                }

                // Update volume level
                self.currentInputVolume = rms

                // Notify volume changes
                DispatchQueue.main.async {
                    self.callbacks.onVolumeUpdate(rms)
                }
            }
        }

        private func updateVolume(_ buffer: AVAudioPCMBuffer) {
            guard let channelData = buffer.floatChannelData else { return }

            var sum: Float = 0
            let channelCount = Int(buffer.format.channelCount)

            for channel in 0 ..< channelCount {
                let data = channelData[channel]
                for i in 0 ..< Int(buffer.frameLength) {
                    sum += abs(data[i])
                }
            }

            let average = sum / Float(buffer.frameLength * buffer.format.channelCount)
            let meterLevel = 20 * log10(average)

            // Normalize the meter level to a 0-1 range
            currentInputVolume = max(0, min(1, (meterLevel + 50) / 50))
        }

        private func addAudioBase64Chunk(_ chunk: String) {
            guard let data = ElevenLabsSDK.base64ToArrayBuffer(chunk) else {
                callbacks.onError("Failed to decode audio chunk", nil)
                return
            }

            let sampleRate = Double(connection.sampleRate)
            guard let audioFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                callbacks.onError("Failed to create AVAudioFormat", nil)
                return
            }

            let frameCount = data.count / MemoryLayout<Int16>.size

            if frameCount > 0 {
                guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
                    callbacks.onError("Failed to create AVAudioPCMBuffer", nil)
                    return
                }

                audioBuffer.frameLength = AVAudioFrameCount(frameCount)

                data.withUnsafeBytes { (int16Buffer: UnsafeRawBufferPointer) in
                    guard let int16Pointer = int16Buffer.bindMemory(to: Int16.self).baseAddress else { return }
                    if let floatChannelData = audioBuffer.floatChannelData {
                        for i in 0 ..< frameCount {
                            floatChannelData[0][i] = Float(Int16(littleEndian: int16Pointer[i])) / Float(Int16.max)
                        }
                    }
                }

                audioBufferLock.withLock {
                    audioBuffers.append(audioBuffer)
                }
            }

            scheduleNextBuffer()
        }

        private func scheduleNextBuffer() {
            output.audioQueue.async { [weak self] in
                guard let self = self else { return }

                let buffer: AVAudioPCMBuffer? = self.audioBufferLock.withLock {
                    self.audioBuffers.isEmpty ? nil : self.audioBuffers.removeFirst()
                }

                guard let audioBuffer = buffer else { return }

                self.output.playerNode.scheduleBuffer(audioBuffer) {
                    self.scheduleNextBuffer()
                }
                if !self.output.playerNode.isPlaying {
                    self.output.playerNode.play()
                }
            }
        }

        private func fadeOutAudio() {
            // Mute agent
            updateMode(.listening)

            // Fade out the volume
            let fadeOutDuration: TimeInterval = 2.0
            output.mixer.volume = volume
            output.mixer.volume = 0.0001

            // Reset volume back after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutDuration) { [weak self] in
                guard let self = self else { return }
                self.output.mixer.volume = self.volume
                self.clearAudioBuffers()
            }
        }

        private func updateMode(_ newMode: Mode) {
            guard mode != newMode else { return }
            mode = newMode
            callbacks.onModeChange(newMode)
        }

        private func updateStatus(_ newStatus: Status) {
            guard status != newStatus else { return }
            status = newStatus
            callbacks.onStatusChange(newStatus)
        }

        /// Send a contextual update event
        // non blocking, does not trigger a turn
        public func sendContextualUpdate(_ text: String) {
            let event: [String: Any] = [
                "type": "contextual_update",
                "text": text,
            ]
            sendWebSocketMessage(event)
        }

        /// Send a user message event
        /// - Parameter text: The text message to send (optional)
        // triggers a turn without requiring audio, audio still processed
        public func sendUserMessage(_ text: String? = nil) {
            var event: [String: Any] = [
                "type": "user_message",
            ]
            if let text = text {
                event["text"] = text
            }
            sendWebSocketMessage(event)
        }

        /// Send a user activity event , prevents interruption due to turn timeout
        public func sendUserActivity() {
            let event: [String: Any] = [
                "type": "user_activity",
            ]
            sendWebSocketMessage(event)
        }

        /// Ends the current conversation session
        public func endSession() {
            guard status == .connected else { return }

            updateStatus(.disconnecting)
            connection.close()
            input.close()
            output.close()
            updateStatus(.disconnected)

            DispatchQueue.main.async {
                self.inputVolumeUpdateTimer?.invalidate()
                self.inputVolumeUpdateTimer = nil
            }
        }

        /// Retrieves the conversation ID
        /// - Returns: Conversation identifier
        public func getId() -> String {
            connection.conversationId
        }

        /// Retrieves the input volume
        /// - Returns: Current input volume
        public func getInputVolume() -> Float {
            0
        }

        /// Retrieves the output volume
        /// - Returns: Current output volume
        public func getOutputVolume() -> Float {
            output.mixer.volume
        }

        /// Starts recording audio input
        public func startRecording() {
            isProcessingInput = true
        }

        /// Stops recording audio input
        public func stopRecording() {
            isProcessingInput = false
        }

        private func clearAudioBuffers() {
            audioBufferLock.withLock {
                audioBuffers.removeAll()
            }
            audioConcatProcessor.handleMessage(["type": "clearInterrupted"])
        }

        private func stopPlayback() {
            output.audioQueue.async { [weak self] in
                guard let self = self else { return }
                self.output.playerNode.stop()
            }
        }
    }

    // MARK: - Errors

    /// Defines errors specific to ElevenLabsSDK
    public enum ElevenLabsError: Error, LocalizedError {
        case invalidConfiguration
        case invalidURL
        case invalidInitialMessageFormat
        case unexpectedBinaryMessage
        case unknownMessageType
        case failedToCreateAudioFormat
        case failedToCreateAudioComponent
        case failedToCreateAudioComponentInstance

        public var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                return "Invalid configuration provided."
            case .invalidURL:
                return "The provided URL is invalid."
            case .failedToCreateAudioFormat:
                return "Failed to create the audio format."
            case .failedToCreateAudioComponent:
                return "Failed to create audio component."
            case .failedToCreateAudioComponentInstance:
                return "Failed to create audio component instance."
            case .invalidInitialMessageFormat:
                return "The initial message format is invalid."
            case .unexpectedBinaryMessage:
                return "Received an unexpected binary message."
            case .unknownMessageType:
                return "Received an unknown message type."
            }
        }
    }

    // MARK: - Audio Session Configuration

    private static func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        let logger = Logger(subsystem: "com.elevenlabs.ElevenLabsSDK", category: "AudioSession")

        do {
            // ALWAYS configure with .voiceChat initially. The override handles older devices later.
            let sessionMode: AVAudioSession.Mode = .voiceChat
            logger.info("Configuring session with category: .playAndRecord, mode: .voiceChat")
            try audioSession.setCategory(.playAndRecord, mode: sessionMode, options: [.defaultToSpeaker, .allowBluetooth])

            // Keep preferred settings
            try audioSession.setPreferredIOBufferDuration(Constants.ioBufferDuration)
            logger.debug("Set preferred IO buffer duration to \(Constants.ioBufferDuration)")

            try audioSession.setPreferredSampleRate(Constants.inputSampleRate)
            logger.debug("Set preferred sample rate to \(Constants.inputSampleRate)")

            // Set input gain if possible
            if audioSession.isInputGainSettable {
                try audioSession.setInputGain(1.0)
                logger.debug("Set input gain to 1.0")
            } else {
                logger.debug("Input gain is not settable.")
            }

            // Activate the session
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            logger.info("Audio session configured and activated.")

        } catch {
            logger.error("Failed to configure audio session: \(error.localizedDescription)")
            print("ElevenLabsSDK: Failed to configure audio session: \(error.localizedDescription)")
            throw error
        }
    }
}

extension NSLock {
    /// Executes a closure within a locked context
    /// - Parameter body: Closure to execute
    /// - Returns: Result of the closure
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension Data {
    /// Initializes `Data` from an array of Int16
    /// - Parameter buffer: Array of Int16 values
    init(buffer: [Int16]) {
        self = buffer.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

extension Encodable {
    var dictionary: [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: .allowFragments)) as? [String: Any]
    }
}

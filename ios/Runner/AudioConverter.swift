import Foundation
import AVFoundation

/// Native iOS audio converter using AVFoundation.
/// Converts various audio/video formats to 16kHz mono PCM WAV for local ASR.
/// Uses streaming to handle long audio files without running out of memory.
class AudioConverter {
    
    static let targetSampleRate: Double = 16000
    static let targetChannels: UInt32 = 1
    
    // Throttling: yield every N buffers to reduce CPU heat
    static let yieldEveryBuffers = 50
    static let yieldDurationMs: UInt32 = 5
    
    /// Convert audio/video file to 16kHz mono WAV using streaming.
    func convertToWav16kMono(inputPath: String, outputPath: String, completion: @escaping (Result<String, Error>) -> Void) {
        // Run on background queue with utility QoS to reduce CPU pressure
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    completion(.failure(AudioConverterError.readerCreationFailed))
                }
                return
            }
            
            let result = self.convertSync(inputPath: inputPath, outputPath: outputPath)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
    
    private func convertSync(inputPath: String, outputPath: String) -> Result<String, Error> {
        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = URL(fileURLWithPath: outputPath)
        
        // Delete existing output file if any
        try? FileManager.default.removeItem(at: outputURL)
        
        let asset = AVURLAsset(url: inputURL)
        
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            return .failure(AudioConverterError.noAudioTrack)
        }
        
        // Setup reader
        guard let reader = try? AVAssetReader(asset: asset) else {
            return .failure(AudioConverterError.readerCreationFailed)
        }
        
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioConverter.targetSampleRate,
            AVNumberOfChannelsKey: AudioConverter.targetChannels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false
        
        guard reader.canAdd(readerOutput) else {
            return .failure(AudioConverterError.cannotAddOutput)
        }
        reader.add(readerOutput)
        
        // Create output file with placeholder WAV header
        guard FileManager.default.createFile(atPath: outputPath, contents: nil) else {
            return .failure(AudioConverterError.readingFailed("Cannot create output file"))
        }
        
        guard let fileHandle = try? FileHandle(forWritingTo: outputURL) else {
            return .failure(AudioConverterError.readingFailed("Cannot open output file"))
        }
        
        defer {
            try? fileHandle.close()
        }
        
        // Write placeholder header
        let headerData = createWavHeader(dataSize: 0)
        try? fileHandle.write(contentsOf: headerData)
        
        // Start reading
        guard reader.startReading() else {
            return .failure(AudioConverterError.readingFailed(reader.error?.localizedDescription ?? "Unknown"))
        }
        
        var totalDataSize: UInt32 = 0
        var bufferCount = 0
        
        // Stream samples directly to file
        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            autoreleasepool {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
                
                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                
                let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
                
                if status == kCMBlockBufferNoErr, let dataPointer = dataPointer, length > 0 {
                    let data = Data(bytes: dataPointer, count: length)
                    try? fileHandle.write(contentsOf: data)
                    totalDataSize += UInt32(length)
                    
                    // Throttle: yield periodically to prevent CPU overheating
                    bufferCount += 1
                    if bufferCount % AudioConverter.yieldEveryBuffers == 0 {
                        usleep(AudioConverter.yieldDurationMs * 1000)
                    }
                }
            }
        }
        
        if reader.status != .completed {
            return .failure(AudioConverterError.readingFailed(reader.error?.localizedDescription ?? "Incomplete"))
        }
        
        // Update WAV header with actual size
        updateWavHeader(fileHandle: fileHandle, dataSize: totalDataSize)
        
        return .success(outputPath)
    }
    
    private func createWavHeader(dataSize: UInt32) -> Data {
        var header = Data()
        
        let sampleRate = UInt32(AudioConverter.targetSampleRate)
        let channels: UInt16 = UInt16(AudioConverter.targetChannels)
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let fileSize = 36 + dataSize
        
        // RIFF header
        header.append("RIFF".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        header.append("WAVE".data(using: .ascii)!)
        
        // fmt chunk
        header.append("fmt ".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        
        // data chunk
        header.append("data".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        
        return header
    }
    
    private func updateWavHeader(fileHandle: FileHandle, dataSize: UInt32) {
        let fileSize = 36 + dataSize
        
        // Update RIFF chunk size at offset 4
        try? fileHandle.seek(toOffset: 4)
        try? fileHandle.write(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        
        // Update data chunk size at offset 40
        try? fileHandle.seek(toOffset: 40)
        try? fileHandle.write(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
    }
}

enum AudioConverterError: LocalizedError {
    case noAudioTrack
    case readerCreationFailed
    case cannotAddOutput
    case readingFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "No audio track found in file"
        case .readerCreationFailed:
            return "Failed to create asset reader"
        case .cannotAddOutput:
            return "Cannot add reader output"
        case .readingFailed(let reason):
            return "Reading failed: \(reason)"
        }
    }
}

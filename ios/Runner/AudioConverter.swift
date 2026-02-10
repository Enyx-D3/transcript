import Foundation
import AVFoundation

/// Native iOS audio converter using AVFoundation.
/// Converts various audio/video formats to 16kHz mono PCM WAV for Whisper.
class AudioConverter {
    
    static let targetSampleRate: Double = 16000
    static let targetChannels: UInt32 = 1
    
    /// Convert audio/video file to 16kHz mono WAV.
    func convertToWav16kMono(inputPath: String, outputPath: String, completion: @escaping (Result<String, Error>) -> Void) {
        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = URL(fileURLWithPath: outputPath)
        
        // Delete existing output file if any
        try? FileManager.default.removeItem(at: outputURL)
        
        let asset = AVURLAsset(url: inputURL)
        
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            completion(.failure(AudioConverterError.noAudioTrack))
            return
        }
        
        // Setup reader
        guard let reader = try? AVAssetReader(asset: asset) else {
            completion(.failure(AudioConverterError.readerCreationFailed))
            return
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
            completion(.failure(AudioConverterError.cannotAddOutput))
            return
        }
        reader.add(readerOutput)
        
        // Read all samples
        guard reader.startReading() else {
            completion(.failure(AudioConverterError.readingFailed(reader.error?.localizedDescription ?? "Unknown")))
            return
        }
        
        var pcmData = Data()
        
        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            
            let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            
            if status == kCMBlockBufferNoErr, let dataPointer = dataPointer {
                pcmData.append(UnsafeBufferPointer(start: dataPointer, count: length))
            }
        }
        
        if reader.status != .completed {
            completion(.failure(AudioConverterError.readingFailed(reader.error?.localizedDescription ?? "Incomplete")))
            return
        }
        
        // Write WAV file
        do {
            let wavData = createWavData(pcmData: pcmData, sampleRate: UInt32(AudioConverter.targetSampleRate), channels: UInt16(AudioConverter.targetChannels))
            try wavData.write(to: outputURL)
            completion(.success(outputPath))
        } catch {
            completion(.failure(error))
        }
    }
    
    private func createWavData(pcmData: Data, sampleRate: UInt32, channels: UInt16) -> Data {
        var wavData = Data()
        
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let fileSize = 36 + dataSize
        
        // RIFF header
        wavData.append("RIFF".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        wavData.append("WAVE".data(using: .ascii)!)
        
        // fmt chunk
        wavData.append("fmt ".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })  // chunk size
        wavData.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })   // PCM format
        wavData.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        
        // data chunk
        wavData.append("data".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wavData.append(pcmData)
        
        return wavData
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

// Test-owned synthesized audio only. Concatenate actual PCM with explicit pauses,
// avoiding speech markup interpretation by the system voice synthesizer.
import AVFoundation
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let names = ["notes.aiff", "safari.aiff", "chrome.aiff", "github.aiff"]
let first = try AVAudioFile(forReading: root.appendingPathComponent(names[0]))
let format = first.processingFormat
precondition(format.channelCount == 1 && format.commonFormat == .pcmFormatFloat32)
let output = try AVAudioFile(forWriting: root.appendingPathComponent("continuation.caf"), settings: format.settings)
for (index, name) in names.enumerated() {
    let file = try AVAudioFile(forReading: root.appendingPathComponent(name))
    precondition(file.processingFormat == format)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer); try output.write(from: buffer)
    if index < names.count - 1 {
        let frames = AVAudioFrameCount(format.sampleRate * 1.6)
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        silence.frameLength = frames
        silence.floatChannelData![0].initialize(repeating: 0, count: Int(frames))
        try output.write(from: silence)
    }
}

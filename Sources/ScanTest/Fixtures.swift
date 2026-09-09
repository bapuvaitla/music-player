import Foundation
import AVFoundation
import AppKit

// Generates the real, playable audio fixtures ScanTest's regression suite
// exercises (Rock/Jazz/Electronic folders with one track each in several
// formats). Previously these lived by hand in a scratchpad tmp directory
// and silently vanished once macOS's periodic /tmp cleanup ran, breaking
// every future session. Regenerating them here means `swift run ScanTest
// <any-writable-dir>` always has what it needs, from a clean checkout.

func generateFixtures(in testDir: URL) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: testDir, withIntermediateDirectories: true)

    let rockAlbumA = testDir.appendingPathComponent("Rock/AlbumA")
    let jazzAlbumB = testDir.appendingPathComponent("Jazz/AlbumB")
    let electronicAlbumD = testDir.appendingPathComponent("Electronic/AlbumD")

    for genreDir in ["Rock", "Jazz", "Electronic"] {
        try? fm.removeItem(at: testDir.appendingPathComponent(genreDir))
    }
    for dir in [rockAlbumA, jazzAlbumB, electronicAlbumD] {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    let scratch = fm.temporaryDirectory.appendingPathComponent("MusicPlayerScanTestSource-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch) }

    func sourceWav(_ name: String, frequency: Double, duration: Double) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try writeSineWav(to: url, frequency: frequency, duration: duration)
        return url
    }

    // track1.m4a — Rock/AlbumA. Needs embedded artwork (ArtworkLoader test)
    // and enough duration to survive the play/pause/artwork Now Playing
    // exercise near the end of the suite.
    let track1Source = try sourceWav("track1.wav", frequency: 440, duration: 4.0)
    let artwork = makeTestPNG(size: NSSize(width: 16, height: 16), color: .systemBlue)
    try await exportM4A(
        source: track1Source,
        destination: rockAlbumA.appendingPathComponent("track1.m4a"),
        title: "Track One", artist: "Rock Artist", album: "AlbumA",
        artworkData: artwork
    )

    // track2.aiff — Rock/AlbumA. Needed for the replaceFile test, which
    // looks up an .aiff track whose path contains "AlbumA".
    let track2Source = try sourceWav("track2.wav", frequency: 523, duration: 1.2)
    try convert(track2Source, to: rockAlbumA.appendingPathComponent("track2.aiff"), format: "AIFF", dataFormat: "BEI16")

    // track3.wav — Jazz/AlbumB. Duration matters: the rewind and
    // loop-region playback tests assume ~1.65s (short enough that
    // unlooped playback would finish inside their sleep windows).
    try writeSineWav(to: jazzAlbumB.appendingPathComponent("track3.wav"), frequency: 349, duration: 1.65)

    // track4.mp3 — Jazz/AlbumB. Exact path is referenced directly by the
    // individual-file-import test.
    let track4Source = try sourceWav("track4.wav", frequency: 392, duration: 1.2)
    try encodeMP3(
        track4Source, to: jazzAlbumB.appendingPathComponent("track4.mp3"),
        title: "Track Four", artist: "Jazz Artist", album: "AlbumB", genre: "Jazz", trackNumber: 4
    )

    // track5.flac — Electronic/AlbumD. Needed as the "new file" swapped in
    // by the replaceFile test.
    let track5Source = try sourceWav("track5.wav", frequency: 293, duration: 1.2)
    try convert(track5Source, to: electronicAlbumD.appendingPathComponent("track5.flac"), format: "flac", dataFormat: "flac")

    // track6.m4a — Electronic/AlbumD, rounding the folder out to 2 tracks
    // (6 total across Rock/Jazz/Electronic, per the multi-folder-merge test).
    let track6Source = try sourceWav("track6.wav", frequency: 261, duration: 1.2)
    try await exportM4A(
        source: track6Source,
        destination: electronicAlbumD.appendingPathComponent("track6.m4a"),
        title: "Track Six", artist: "Electronic Artist", album: "AlbumD",
        artworkData: nil
    )
}

// Hand-rolled instead of AVAudioFile(forWriting:settings:): writing an
// Int16 buffer through that initializer's inferred processing format
// trips a CoreAudio format-mismatch assertion (SIGTRAP inside
// ExtAudioFile) for a plain mono 16-bit settings dictionary. A raw PCM
// WAV header is simple enough to just build directly.
private func writeSineWav(to url: URL, frequency: Double, duration: Double, sampleRate: Double = 44100) throws {
    let frameCount = Int(duration * sampleRate)
    var samples = [Int16](repeating: 0, count: frameCount)
    for i in 0..<frameCount {
        let t = Double(i) / sampleRate
        let value = sin(2 * Double.pi * frequency * t) * 0.4
        samples[i] = Int16(value * Double(Int16.max))
    }

    let bitsPerSample: UInt16 = 16
    let channels: UInt16 = 1
    let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
    let blockAlign = channels * (bitsPerSample / 8)
    let dataSize = UInt32(frameCount * Int(bitsPerSample / 8))

    var data = Data()
    func append(_ s: String) { data.append(s.data(using: .ascii)!) }
    func append(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func append(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

    append("RIFF")
    append(UInt32(36) + dataSize)
    append("WAVE")
    append("fmt ")
    append(UInt32(16))
    append(UInt16(1)) // PCM
    append(channels)
    append(UInt32(sampleRate))
    append(byteRate)
    append(blockAlign)
    append(bitsPerSample)
    append("data")
    append(dataSize)
    samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }

    try data.write(to: url)
}

private func exportM4A(source: URL, destination: URL, title: String, artist: String, album: String, artworkData: Data?) async throws {
    try? FileManager.default.removeItem(at: destination)
    let asset = AVURLAsset(url: source)
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        fail("couldn't create an AVAssetExportSession for \(source.lastPathComponent)")
    }

    func makeItem(_ key: AVMetadataKey, _ value: NSCopying & NSObjectProtocol) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .common
        item.key = key.rawValue as NSString
        item.value = value
        return item
    }

    var metadata = [
        makeItem(.commonKeyTitle, title as NSString),
        makeItem(.commonKeyArtist, artist as NSString),
        makeItem(.commonKeyAlbumName, album as NSString)
    ]
    if let artworkData {
        metadata.append(makeItem(.commonKeyArtwork, artworkData as NSData))
    }
    exportSession.metadata = metadata

    try await exportSession.export(to: destination, as: .m4a)
}

@discardableResult
private func runProcess(executable: String, arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "failed to launch \(executable): \(error)")
    }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

private func convert(_ source: URL, to destination: URL, format: String, dataFormat: String) throws {
    try? FileManager.default.removeItem(at: destination)
    let result = runProcess(executable: "/usr/bin/afconvert", arguments: ["-f", format, "-d", dataFormat, source.path, destination.path])
    if result.status != 0 {
        fail("afconvert failed converting \(source.lastPathComponent) to \(destination.lastPathComponent): \(result.output)")
    }
}

private func findExecutable(_ name: String) -> String? {
    let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func encodeMP3(_ source: URL, to destination: URL, title: String, artist: String, album: String, genre: String, trackNumber: Int) throws {
    try? FileManager.default.removeItem(at: destination)
    let args = ["--silent", "--tt", title, "--ta", artist, "--tl", album, "--tg", genre, "--tn", "\(trackNumber)", source.path, destination.path]

    let result: (status: Int32, output: String)
    if let lamePath = findExecutable("lame") {
        result = runProcess(executable: lamePath, arguments: args)
    } else {
        result = runProcess(executable: "/usr/bin/env", arguments: ["lame"] + args)
    }

    if result.status != 0 || !FileManager.default.fileExists(atPath: destination.path) {
        fail("""
        couldn't encode the mp3 test fixture — the `lame` encoder isn't available (afconvert can only decode mp3 on macOS, not encode it).
        Install it once with `brew install lame`, then re-run ScanTest.
        \(result.output)
        """)
    }
}

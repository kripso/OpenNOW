import Foundation

/// The game-audio receive path: SRTP in, interleaved PCM out.
///
/// Each stage already exists and is tested on its own — decryption, reordering, concealment
/// signalling, Opus decode — so this type's job is the ordering and the accounting between them.
/// The sequence it enforces is the one that matters: decrypt before reorder (a packet cannot be
/// ordered until its tag has been verified), and reorder before decode (Opus has no idea what order
/// frames arrived in).
public final class NvstAudioReceivePipeline: @unchecked Sendable {
    public struct Counters: Equatable, Sendable {
        public var datagrams: UInt64 = 0
        public var authenticated: UInt64 = 0
        public var authenticationFailures: UInt64 = 0
        public var replayDrops: UInt64 = 0
        public var packetsDecoded: UInt64 = 0
        public var packetsLost: UInt64 = 0
        public var decodeFailures: UInt64 = 0
        public var concealedFrames: UInt64 = 0
        /// Frames that arrived as a repeat inside a later RED packet and were slotted back into
        /// their original position, so a loss never reached the decoder.
        public var recoveredPackets: UInt64 = 0
        public var malformedRedPackets: UInt64 = 0
        /// Everything that arrived on the socket, before any of it was judged.
        public var datagramBytes: UInt64 = 0
        /// Interleaved samples the decoder actually produced.
        public var decodedSamples: UInt64 = 0
        /// Frames the device had to play as silence because nothing was ready, once audio had
        /// started: audio that arrived late, or never arrived.
        public var starvedFrames: UInt64 = 0
        /// Lost packets whose time the device had already filled with silence while waiting for
        /// them, so they were not concealed a second time.
        public var lostPacketsAlreadyPlayed: UInt64 = 0
        /// Frames removed because they had queued up behind the device and were never needed to
        /// cover a late arrival (see `NvstAudioPlayoutLevel`).
        public var trimmedFrames: UInt64 = 0
        public var ssrc: UInt32?
    }

    /// The payload type the seat's redundant audio is wrapped in. The primary inside it is the
    /// codec's own type.
    public static let redundantPayloadType: UInt8 = 63

    public let channels: Int
    public let framesPerPacket: Int

    private let srtp: NvstAudioSrtp
    private let lock = NSLock()
    private let decoder: NvstOpusDecoder
    private var jitter: NvstAudioJitterBuffer
    private var counters = Counters()
    private var replayWindows: [UInt32: SrtpReplayWindow] = [:]
    private var bufferedSamples: [Float] = []
    private var sampleOffset = 0
    private var level = NvstAudioPlayoutLevel()
    /// Frames the device has played as silence since the last real audio. A packet declared lost
    /// inside that stretch has already had its time played out, so it is skipped rather than
    /// concealed a second time. Real audio ends the stretch: anything it brings late is the playout
    /// level's to win back, not a credit against later losses.
    private var silencePlayedFrames = 0
    private var hasPlayedAudio = false
    private var peakQueuedFrames = 0

    public init(srtp: NvstAudioSrtp,
                framesPerPacket: Int = 240,
                channels: Int = 2,
                targetDepth: Int = 3) throws {
        self.srtp = srtp
        self.framesPerPacket = framesPerPacket
        self.channels = channels
        self.jitter = NvstAudioJitterBuffer(targetDepth: targetDepth)
        self.decoder = try NvstOpusDecoder(framesPerPacket: framesPerPacket)
    }

    public var snapshot: Counters { lock.withLock { counters } }
    /// How long the emitted packets waited in the jitter buffer, and how many were emitted. The HUD
    /// divides one by the other for its A/V reading, exactly as it did over libwebrtc's counters.
    public var jitterBufferDwellSeconds: TimeInterval { lock.withLock { jitter.jitterBufferDelaySeconds } }
    public var jitterBufferEmittedCount: UInt64 { lock.withLock { jitter.jitterBufferEmittedCount } }
    /// Packets the jitter buffer dropped because nothing was playing them out.
    public var overflowDropCount: Int { lock.withLock { jitter.overflowDropCount } }

    /// Audio queued on this device between the network and the speaker, in frames: the most since
    /// the last call, and right now. Both include what the jitter buffer is holding.
    public func drainQueuedFrames() -> (peak: Int, current: Int) {
        lock.withLock {
            let current = queuedFrames
            defer { peakQueuedFrames = current }
            return (max(peakQueuedFrames, current), current)
        }
    }

    private var queuedFrames: Int {
        (bufferedSamples.count - sampleOffset) / channels + jitter.bufferedCount * framesPerPacket
    }

    /// Verifies and queues one datagram. A packet that fails its tag is counted and discarded: it is
    /// indistinguishable from an attacker's, and either way it is not audio.
    ///
    /// A RED packet carries repeats of earlier frames ahead of the frame it was sent for, so the
    /// repeats are slotted back at the sequences they belong to. If one of those was lost, this is
    /// where it is recovered — the seat sent it twice precisely so that a single loss would not
    /// reach the decoder.
    public func ingest(_ datagram: Data) {
        lock.lock()
        defer { lock.unlock() }
        counters.datagrams += 1
        counters.datagramBytes &+= UInt64(datagram.count)
        guard let header = NvstAudioRtpPacket.parse(datagram, tagLength: srtp.authenticationTagLength) else {
            counters.authenticationFailures += 1
            return
        }
        var replayWindow = replayWindows[header.ssrc] ?? SrtpReplayWindow()
        let index = replayWindow.estimatedIndex(for: header.sequenceNumber)
        guard replayWindow.wouldAccept(index) else {
            counters.replayDrops += 1
            return
        }
        do {
            let (packet, payload) = try srtp.unprotect(datagram, rolloverCounter: UInt32(truncatingIfNeeded: index >> 16))
            guard replayWindow.accept(index) else { return }
            replayWindows[packet.ssrc] = replayWindow
            counters.ssrc = packet.ssrc
            counters.authenticated += 1
            guard packet.payloadType == Self.redundantPayloadType else {
                jitter.insert(sequenceNumber: packet.sequenceNumber, payload: payload)
                return
            }
            guard let blocks = NvstRedAudio.split(payload), let primary = blocks.last else {
                counters.malformedRedPackets += 1
                return
            }
            for repeatBlock in blocks.dropLast() {
                let framesBack = Int(repeatBlock.timestampOffset) / max(1, framesPerPacket)
                let sequence = packet.sequenceNumber &- UInt16(truncatingIfNeeded: framesBack)
                jitter.insert(sequenceNumber: sequence, payload: repeatBlock.payload)
                counters.recoveredPackets += 1
            }
            jitter.insert(sequenceNumber: packet.sequenceNumber, payload: primary.payload)
        } catch {
            counters.authenticationFailures += 1
        }
    }

    /// Emits the frames that are ready, in order, with a silent frame standing in for each packet
    /// that never arrived.
    ///
    /// Timing is what concealment has to preserve here: the caller is feeding a device that expects
    /// a fixed rate, so a gap must still consume its 5 ms. Opus's own packet-loss concealment would
    /// fill that gap with extrapolated audio rather than silence, but `AudioConverter` does not
    /// expose it, so silence is used and counted.
    public func pull() -> [Float] {
        lock.withLock {
            defer { bufferedSamples.removeAll(keepingCapacity: true); sampleOffset = 0 }
            return Array(bufferedSamples.dropFirst(sampleOffset)) + drain(jitter.advance())
        }
    }

    public func pull(sampleCount: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard sampleCount > 0 else { return [] }
        if sampleOffset > 0 {
            bufferedSamples.removeFirst(sampleOffset)
            sampleOffset = 0
        }
        bufferedSamples.append(contentsOf: drain(jitter.advance()))
        if bufferedSamples.count < sampleCount {
            bufferedSamples.append(contentsOf: drain(jitter.releaseReady()))
        }
        let count = min(sampleCount, bufferedSamples.count)
        if hasPlayedAudio, count < sampleCount {
            let silent = (sampleCount - count) / channels
            silencePlayedFrames += silent
            counters.starvedFrames &+= UInt64(silent)
        }
        let spareFrames = (bufferedSamples.count - count) / channels
        if let excess = level.observe(renderedFrames: sampleCount / channels, spareFrames: spareFrames) {
            removeFrames(excess, after: count)
        }
        sampleOffset = count
        peakQueuedFrames = max(peakQueuedFrames, queuedFrames)
        return Array(bufferedSamples.prefix(count))
    }

    /// Emits everything still held; the stream is ending, so nothing should be left behind.
    public func flush() -> [Float] {
        lock.withLock {
            defer { bufferedSamples.removeAll(keepingCapacity: true); sampleOffset = 0 }
            return Array(bufferedSamples.dropFirst(sampleOffset)) + drain(jitter.flush())
        }
    }

    /// Drops everything queued, when the device has been rebuilt: what arrived while nothing was
    /// playing is behind the seat by however long that took, and playing it would keep it there.
    public func discardQueuedAudio() {
        lock.lock()
        defer { lock.unlock() }
        let frames = queuedFrames
        bufferedSamples.removeAll(keepingCapacity: true)
        sampleOffset = 0
        jitter.discardPending()
        level = NvstAudioPlayoutLevel()
        silencePlayedFrames = 0
        counters.trimmedFrames &+= UInt64(frames)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        jitter.reset()
        replayWindows.removeAll()
        bufferedSamples.removeAll(keepingCapacity: true)
        sampleOffset = 0
        level = NvstAudioPlayoutLevel()
        silencePlayedFrames = 0
        hasPlayedAudio = false
        peakQueuedFrames = 0
    }

    private func drain(_ emissions: [NvstAudioJitterBuffer.Emission]) -> [Float] {
        var output: [Float] = []
        for emission in emissions {
            switch emission {
            case .payload(let payload):
                do {
                    if let decoded = try decoder.decode(payload) {
                        hasPlayedAudio = true
                        silencePlayedFrames = 0
                        output.append(contentsOf: decoded)
                        counters.packetsDecoded += 1
                        counters.decodedSamples &+= UInt64(decoded.count)
                    }
                } catch {
                    counters.decodeFailures += 1
                    output.append(contentsOf: silence())
                }
            case .lost:
                counters.packetsLost += 1
                if silencePlayedFrames >= framesPerPacket {
                    silencePlayedFrames -= framesPerPacket
                    counters.lostPacketsAlreadyPlayed += 1
                    continue
                }
                counters.concealedFrames += UInt64(framesPerPacket)
                output.append(contentsOf: silence())
            }
        }
        return output
    }

    /// Removes `frames` from the queue just after the `start` samples about to be played,
    /// crossfading across the cut so it does not click.
    private func removeFrames(_ frames: Int, after start: Int) {
        let fade = NvstAudioPlayoutLevel.crossfadeFrames
        let cut = start + frames * channels
        guard frames > 0, cut + fade * channels <= bufferedSamples.count else { return }
        for frame in 0..<fade {
            let incoming = Float(frame + 1) / Float(fade + 1)
            for channel in 0..<channels {
                let outgoing = start + frame * channels + channel
                let kept = cut + frame * channels + channel
                bufferedSamples[kept] = bufferedSamples[outgoing] * (1 - incoming) + bufferedSamples[kept] * incoming
            }
        }
        bufferedSamples.removeSubrange(start..<cut)
        counters.trimmedFrames &+= UInt64(frames)
    }

    private func silence() -> [Float] {
        [Float](repeating: 0, count: framesPerPacket * channels)
    }

}

/// Keeps the audio's delay at what the network actually needs.
///
/// Nothing downstream plays faster than real time, so audio that arrives late plays late: a
/// network pause renders as silence, and the burst that follows it waits behind the device. That
/// queue is worth keeping only while it absorbs the pauses that follow. This records, for each
/// one-second window, the least audio left over after any render. Whatever none of the last five
/// windows needed is removed: pauses that keep coming keep their cushion, while one that does not
/// recur, a device that stopped, or a seat clock running fast stops costing delay five seconds
/// later, the same hold the video's Wi-Fi pause smoothing uses. Anything beyond 150 ms, that
/// smoothing's ceiling, goes at the render it appears.
struct NvstAudioPlayoutLevel: Sendable {
    /// One second at 48 kHz.
    static let windowFrames = 48_000
    static let windowsRemembered = 5
    /// What a trim leaves beyond the least spare the remembered windows saw: 5 ms.
    static let marginFrames = 240
    /// 150 ms.
    static let maximumCushionFrames = 7_200
    /// Excess smaller than one packet is left alone, so slow clock drift does not splice constantly.
    static let minimumTrimFrames = 240
    /// 2.5 ms crossfade across each cut.
    static let crossfadeFrames = 120

    private var renderedFrames = 0
    private var leastSpareFrames = Int.max
    /// Each completed window's least spare, oldest first.
    private var recentLeastSpare: [Int] = []

    /// Called after each render with what is still queued behind it. Returns how many frames to
    /// remove: anything beyond the ceiling at once, and what no remembered window needed at the
    /// end of each window.
    mutating func observe(renderedFrames rendered: Int, spareFrames: Int) -> Int? {
        var removed = 0
        let beyondCeiling = spareFrames - Self.marginFrames - Self.maximumCushionFrames
        if beyondCeiling >= Self.minimumTrimFrames { removed = shorten(by: beyondCeiling) }
        leastSpareFrames = min(leastSpareFrames, spareFrames - removed)
        renderedFrames += rendered
        if renderedFrames >= Self.windowFrames {
            recentLeastSpare.append(leastSpareFrames)
            if recentLeastSpare.count > Self.windowsRemembered { recentLeastSpare.removeFirst() }
            renderedFrames = 0
            leastSpareFrames = Int.max
            let unneeded = (recentLeastSpare.min() ?? 0) - Self.marginFrames
            if unneeded >= Self.minimumTrimFrames { removed += shorten(by: unneeded) }
        }
        return removed > 0 ? removed : nil
    }

    /// The queue is shorter by `frames` from now on, in what each remembered window left over too.
    private mutating func shorten(by frames: Int) -> Int {
        recentLeastSpare = recentLeastSpare.map { max(0, $0 - frames) }
        if leastSpareFrames != Int.max { leastSpareFrames = max(0, leastSpareFrames - frames) }
        return frames
    }
}

//  The receiver's feedback plane: SRTCP indices, receiver reports, the drain loop and the socket
//  itself.
//

import Foundation
import Testing
@testable import OpenNOWiOS

@Suite(.serialized)
struct NvstMjolnirFeedbackTests {
    @Test func videoStartupRequestsKeyframesWithoutAnyMediaArrival() {
        var liveness = NativeStreamVideoLiveness(now: 0)
        #expect(liveness.observe(decoded: 0, now: 999_999_999) == .none)
        #expect(liveness.observe(decoded: 0, now: 1_000_000_000) == .requestKeyframe)
        #expect(liveness.observe(decoded: 0, now: 1_500_000_000) == .none)
        #expect(liveness.observe(decoded: 0, now: 2_000_000_000) == .requestKeyframe)
        #expect(liveness.observe(decoded: 0, now: 19_000_000_000) == .requestKeyframe)
        #expect(liveness.observe(decoded: 0, now: 20_000_000_000) == .failed)
    }

    @Test func onlyNewDecoderOutputResetsVideoStallRecovery() {
        var liveness = NativeStreamVideoLiveness(now: 0)
        #expect(liveness.observe(decoded: 1, now: 500_000_000) == .none)
        #expect(liveness.observe(decoded: 1, now: 1_500_000_000) == .requestKeyframe)
        #expect(liveness.observe(decoded: 2, now: 1_600_000_000) == .none)
        #expect(liveness.observe(decoded: 2, now: 2_599_999_999) == .none)
        #expect(liveness.observe(decoded: 2, now: 2_600_000_000) == .requestKeyframe)
        #expect(liveness.observe(decoded: 2, now: 21_600_000_000) == .failed)
    }

    @Test func newVideoAttachmentStartsWithANewRecoveryBudget() {
        var liveness = NativeStreamVideoLiveness(now: 0)
        #expect(liveness.observe(decoded: 0, now: 20_000_000_000) == .failed)
        liveness = NativeStreamVideoLiveness(now: 30_000_000_000)
        #expect(liveness.observe(decoded: 0, now: 30_000_000_000) == .none)
        #expect(liveness.observe(decoded: 0, now: 31_000_000_000) == .requestKeyframe)
    }

    /// SRTCP feedback sealed at a constant index 0 is accepted by the seat's replay window exactly
    /// once per session; every later PLI and NACK was silently discarded (and reused a GCM nonce).
    @Test func srtcpFeedbackIndexesAreMonotonic() throws {
        let receiver = try NvstMjolnirReceiver(handoff: NvstReceiverFixtures.makeHandoff())
        #expect(receiver.nextSrtcpIndex() == 0)
        #expect(receiver.nextSrtcpIndex() == 1)
        #expect(receiver.nextSrtcpIndex() == 2)
        #expect(receiver.srtcpFeedbackIndex == 3)
    }

    @Test func aGapBeyondTheReorderWindowRequestsRecoveryAndNeverEmitsAPartialFrame() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 4)
        let receiver = try NvstVideoReceiver(handoff: handoff)
        let sof = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: 1, frameIndex: 1, flags: 0x05, media: [0x00, 0x00, 0x00, 0x01, 0x65]), sequence: 1, handoff: handoff)
        #expect(NvstReceiverFixtures.frames(receiver.process(datagram: sof)).isEmpty)
        // Jump far past the window: the reference chain is broken.
        let far = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: 40, frameIndex: 2, flags: 0x01, media: [0xaa]), sequence: 40, handoff: handoff)
        let events = receiver.process(datagram: far)
        #expect(NvstReceiverFixtures.recoveries(events) == 1)
        #expect(NvstReceiverFixtures.frames(events).isEmpty)
        #expect(receiver.snapshot.recoveries == 1)
    }

    /// The OS default receive buffer drops the tail of a 5K keyframe burst, which is
    /// indistinguishable from network loss and unrecoverable without FEC.
    @Test func theReceiveBufferIsGrownBeyondTheOsDefault() {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        var initial: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &initial, &length) == 0)

        let granted = NvstMjolnirReceiver.growReceiveBuffer(descriptor)
        #expect(granted >= Int(initial))
        #expect(granted >= 256 * 1024)
    }

    /// A kernel that refuses every request must still leave a working socket.
    @Test func anUngrowableSocketKeepsItsExistingBuffer() {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        // `first` below `last` means the loop body never runs; the reported size is what was there.
        let granted = NvstMjolnirReceiver.growReceiveBuffer(descriptor, first: 1024, last: 4096)
        #expect(granted > 0)
    }

    /// A video sender that never hears a receiver report backs its bitrate off, so this path
    /// producing nothing looks like a slow stream rather than a dead feedback plane.
    @Test func aReceiverReportIsProducedOnceAnSsrcIsBound() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 4)
        let receiver = try NvstVideoReceiver(handoff: handoff)
        // No SSRC bound yet, so nothing to report about.
        #expect(receiver.pollReceiverReport() == nil)

        let sof = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: 1, frameIndex: 1, flags: 0x05, media: [0x00, 0x00, 0x00, 0x01, 0x65]), sequence: 1, handoff: handoff)
        _ = receiver.process(datagram: sof)
        #expect(receiver.snapshot.boundSSRC != nil)

        let report = receiver.pollReceiverReport()
        #expect(report != nil)
        // And it is rate limited rather than sent per packet.
        #expect(receiver.pollReceiverReport() == nil)
    }

    /// The drain loop used to run until the socket ran dry, which on a busy media socket is never:
    /// it monopolised its queue and starved the feedback timer, so a 1 s repeating report fired
    /// once in 30 s and the sender never heard from us.
    /// Reporting zeros for loss and jitter describes a receiver that has never seen a packet.
    /// The sender's rate control reads these, so they have to be real.
    @Test func receiverReportsCarryRealReceptionStatistics() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 8)
        let receiver = try NvstVideoReceiver(handoff: handoff)
        for sequence in UInt16(1)...UInt16(6) {
            let datagram = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: sequence, frameIndex: UInt32(sequence), flags: 0x05,
                                           media: [0x00, 0x00, 0x00, 0x01, 0x65]),
                                    sequence: sequence, handoff: handoff)
            _ = receiver.process(datagram: datagram)
        }
        let report = try #require(receiver.pollReceiverReport())
        // RTCP RR: 8-byte header, then the report block. Highest sequence sits at block offset 8.
        let bytes = [UInt8](report)
        #expect(bytes.count > 30)
        // Nothing was lost, so the fraction-lost byte stays zero — but it is now derived, and the
        // reported highest sequence tracks what actually arrived rather than staying at zero.
        #expect(receiver.snapshot.highestSequence == 6)
        #expect(receiver.snapshot.authenticatedPackets == 6)
    }

    @Test func theDrainLoopIsBoundedPerWakeUp() {
        #expect(NvstMjolnirReceiver.maxDatagramsPerWakeUp > 0)
        #expect(NvstMjolnirReceiver.maxDatagramsPerWakeUp <= 256)
    }

    @Test func outOfOrderPacketsAreDeliveredInSequence() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 8)
        let receiver = try NvstVideoReceiver(handoff: handoff)
        let sof = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: 1, frameIndex: 3, flags: 0x05, media: [0x00, 0x00, 0x00, 0x01, 0x65]), sequence: 1, handoff: handoff)
        let eof = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: 3, frameIndex: 3, flags: 0x03, media: [0xcc]), sequence: 3, handoff: handoff)
        let middle = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: 2, frameIndex: 3, flags: 0x01, media: [0xbb]), sequence: 2, handoff: handoff)

        #expect(NvstReceiverFixtures.frames(receiver.process(datagram: sof)).isEmpty)
        // The end-of-frame arrives early and must wait for the middle packet.
        #expect(NvstReceiverFixtures.frames(receiver.process(datagram: eof)).isEmpty)
        let emitted = NvstReceiverFixtures.frames(receiver.process(datagram: middle))
        #expect(emitted.count == 1)
        #expect(emitted[0].bytes == Data([0x00, 0x00, 0x00, 0x01, 0x65, 0xbb, 0xcc]))
    }

    /// The windows that hold a gap open are counted in packets. One lost packet of a two-packet
    /// frame used to hold back every frame behind it until the whole window had gone by; nothing
    /// can still fill the gap once a frame two past it has started.
    @Test func aLostPacketStopsHoldingFramesBackOnceTwoLaterFramesHaveStarted() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 32)
        let receiver = try NvstVideoReceiver(handoff: handoff)
        func deliver(_ sequence: UInt16, frame: UInt32, start: Bool) throws -> [NvstReceiveEvent] {
            let media: [UInt8] = start ? [0x00, 0x00, 0x00, 0x01, 0x65] : [0xcc]
            return receiver.process(datagram: try NvstReceiverFixtures.seal(
                NvstReceiverFixtures.packet(sequence: sequence, frameIndex: frame, flags: start ? 0x05 : 0x03, media: media),
                sequence: sequence, handoff: handoff))
        }
        _ = try deliver(1, frame: 1, start: true)
        #expect(NvstReceiverFixtures.frames(try deliver(2, frame: 1, start: false)).count == 1)
        // Frame 2 loses its first packet (sequence 3).
        #expect(NvstReceiverFixtures.frames(try deliver(4, frame: 2, start: false)).isEmpty)
        // Frame 3 arrives whole, but one frame of slack is kept for a late packet.
        _ = try deliver(5, frame: 3, start: true)
        let held = try deliver(6, frame: 3, start: false)
        #expect(NvstReceiverFixtures.frames(held).isEmpty)
        #expect(NvstReceiverFixtures.recoveries(held) == 0)
        // Frame 4 starting ends the wait: the loss is reported and frame 3 is released.
        let released = try deliver(7, frame: 4, start: true)
        #expect(NvstReceiverFixtures.recoveries(released) == 1)
        #expect(NvstReceiverFixtures.frames(released).map(\.frameIndex) == [3])
        #expect(receiver.snapshot.finalizedLossPackets == 1)
        #expect(NvstReceiverFixtures.frames(try deliver(8, frame: 4, start: false)).map(\.frameIndex) == [4])
    }

    /// With repair data on, the hold is 1,200 packets — about a second of a 12 Mb/s stream. A loss
    /// the repair data can fix must still be fixed; one it cannot fix must not wait that long.
    @Test func repairDataFixesOneLossAndAnUnfixableLossIsGivenUpAfterTwoFrames() throws {
        let handoff = NvstReceiverFixtures.makeHandoff()
        let receiver = try NvstVideoReceiver(handoff: handoff)
        func deliver(frame: UInt32, dropping lost: Set<Int> = []) throws -> [NvstReceiveEvent] {
            let packets = NvstReceiverFixtures.protectedFrame(frameIndex: frame, firstSequence: UInt16((frame - 1) * 5 + 1))
            return try packets.enumerated().filter { !lost.contains($0.offset) }.flatMap { _, entry in
                receiver.process(datagram: try NvstReceiverFixtures.seal(entry.packet, sequence: entry.sequence, handoff: handoff))
            }
        }
        // Four clean frames prove the repair scheme on this stream, which switches it on.
        for frame in 1...4 {
            #expect(NvstReceiverFixtures.frames(try deliver(frame: UInt32(frame))).count == 1)
        }
        #expect(receiver.fecFindings.isArmed)

        // One packet lost out of four, one repair packet: rebuilt, no recovery needed.
        let repaired = try deliver(frame: 5, dropping: [1])
        #expect(NvstReceiverFixtures.frames(repaired).map(\.frameIndex) == [5])
        #expect(NvstReceiverFixtures.recoveries(repaired) == 0)
        #expect(receiver.snapshot.recoveredPackets == 1)

        // Two lost: beyond repair. The next frame is held for one frame of slack...
        #expect(NvstReceiverFixtures.frames(try deliver(frame: 6, dropping: [1, 2])).isEmpty)
        let held = try deliver(frame: 7)
        #expect(NvstReceiverFixtures.frames(held).isEmpty)
        #expect(NvstReceiverFixtures.recoveries(held) == 0)
        // ...and released when the frame after it starts, long before 1,200 packets have passed.
        let released = try deliver(frame: 8)
        #expect(NvstReceiverFixtures.recoveries(released) == 1)
        #expect(NvstReceiverFixtures.frames(released).map(\.frameIndex) == [7, 8])
        #expect(receiver.snapshot.finalizedLossPackets == 2)
    }

    @Test func fecRepairPacketsAreCountedNotDecoded() throws {
        let handoff = NvstReceiverFixtures.makeHandoff()
        let receiver = try NvstVideoReceiver(handoff: handoff)
        let repair = NvstVideoPacketTests.buildPacket(sequence: 1, frameIndex: 1, flags: 0x05, media: [0x00, 0x00, 0x00, 0x01, 0x65], fecWord: 0x00c0_3420)
        let events = receiver.process(datagram: try NvstReceiverFixtures.seal(repair, sequence: 1, handoff: handoff))
        #expect(NvstReceiverFixtures.frames(events).isEmpty)
        #expect(receiver.snapshot.fecPackets == 1)
    }

    @Test func srtcpReceiverReportsWaitForTheMediaSsrcThenRespectTheInterval() throws {
        let handoff = NvstReceiverFixtures.makeHandoff()
        let receiver = try NvstVideoReceiver(handoff: handoff)
        let origin = Date(timeIntervalSince1970: 1_000_000)
        // No authenticated packet yet: nothing to report about.
        #expect(receiver.pollReceiverReport(now: origin) == nil)

        let sof = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: 1, frameIndex: 1, flags: 0x07, media: [0x00, 0x00, 0x00, 0x01, 0x65]), sequence: 1, handoff: handoff)
        _ = receiver.process(datagram: sof)
        let first = receiver.pollReceiverReport(now: origin)
        #expect(first != nil)
        // Sealed SRTCP: an RR (32 bytes) plus the 4-byte E/index trailer and an 8-byte tag.
        #expect(first?.count == 44)
        let opened = try NvstSrtcp.open(srtcpPacket: first!, masterKey: handoff.srtpAESKey, masterSalt: handoff.srtpSalt, senderSSRC: NvstReceiverFixtures.mediaSSRC)
        #expect(opened.rtcp[1] == NvstRtcp.receiverReportPayloadType)
        // At most one report per interval.
        #expect(receiver.pollReceiverReport(now: origin.addingTimeInterval(0.5)) == nil)
        #expect(receiver.pollReceiverReport(now: origin.addingTimeInterval(1.5)) != nil)
    }

    @Test func socketBindsAndStopsCleanly() throws {
        let receiver = try NvstMjolnirReceiver(handoff: NvstReceiverFixtures.makeHandoff())
        try receiver.start()
        receiver.stop()
        #expect(receiver.stats.authenticatedPackets == 0)
    }

    @Test func peerAddressConversionRoundTrips() throws {
        let network = try #require(NvstMjolnirReceiver.inetAddr("10.20.30.40"))
        #expect(NvstMjolnirReceiver.dottedQuad(network) == "10.20.30.40")
        #expect(NvstMjolnirReceiver.inetAddr("10.20.30") == nil)
        #expect(NvstMjolnirReceiver.inetAddr("10.20.30.40.50") == nil)
        #expect(NvstMjolnirReceiver.inetAddr("10.20.30.999") == nil)
    }
}

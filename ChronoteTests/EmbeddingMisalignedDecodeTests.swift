//
//  EmbeddingMisalignedDecodeTests.swift
//  ChronoteTests
//
//  Regression tests for `DiaryEntry.decodeEmbeddingVector` against misaligned
//  underlying `Data` buffers.
//
//  Background — the real-world crash this guards against:
//  Core Data's `allowsExternalBinaryDataStorage="YES"` blob hydrated from
//  CloudKit pull does **not** guarantee a 4-byte-aligned backing pointer.
//  Any decode path that types-the-source (`load(as: UInt32.self)` /
//  `assumingMemoryBound(to: Float.self)` / `bindMemory(to:)`) will trap with
//  `Swift/UnsafeRawPointer.swift:449: Fatal error: load from misaligned raw
//  pointer`. Production code uses `memcpy` to side-step this; these tests pin
//  that contract so a future "harmless" cleanup doesn't regress it.
//
//  Note about constructing misalignment in Swift:
//  `Data.subdata(in:)` *may* re-allocate an aligned backing buffer, but it is
//  not guaranteed to. Even when it does, we cover the contract from the
//  decoder's perspective: it must not assume alignment of the source bytes.
//  The `[0xAA] padding + drop first byte` pattern is the standard idiom for
//  reproducing CloudKit-style misalignment in unit tests.
//

import Testing
import Foundation
@testable import Lumory

// MARK: - Helpers

private func misaligned(_ payload: Data) -> Data {
    // Prepend 1 padding byte and drop it again. Many Data implementations
    // will surface a baseAddress offset from the original allocation by 1,
    // i.e. not aligned to MemoryLayout<UInt32>.alignment.
    var bytes: [UInt8] = [0xAA]
    bytes.append(contentsOf: payload)
    let padded = Data(bytes)
    return padded.subdata(in: 1..<padded.count)
}

private func legacyBareDump(_ vector: [Float]) -> Data {
    var raw = Data()
    vector.withUnsafeBytes { raw.append(contentsOf: $0) }
    return raw
}

// MARK: - Suite

struct EmbeddingMisalignedDecodeTests {
    /// V1 encoded blob, whose Data backing we deliberately offset by 1 byte.
    /// Decoder must return the original vector and must not crash.
    @Test func decodeEmbedding_misalignedV1Buffer_returnsCorrectVector_andDoesNotCrash() {
        let vector: [Float] = [0.0, 1.0, -2.5, 3.125, 42.0]
        let encoded = DiaryEntry.encodeEmbeddingVector(vector)

        let misalignedData = misaligned(encoded)

        // Sanity: the byte content must equal the original encoding.
        #expect(misalignedData.count == encoded.count)
        #expect(Array(misalignedData) == Array(encoded))

        let decoded = DiaryEntry.decodeEmbeddingVector(misalignedData)
        #expect(decoded == vector)
    }

    /// Legacy raw Float32 dump (no header), with deliberately offset backing.
    /// Decoder must return the original vector and must not crash.
    @Test func decodeEmbedding_misalignedLegacyBareDump_returnsCorrectVector_andDoesNotCrash() {
        let vector: [Float] = [0.25, -0.5, 2.0, -7.75]
        let raw = legacyBareDump(vector)

        let misalignedData = misaligned(raw)

        #expect(misalignedData.count == raw.count)
        #expect(Array(misalignedData) == Array(raw))

        let decoded = DiaryEntry.decodeEmbeddingVector(misalignedData)
        #expect(decoded == vector)
    }

    /// Misaligned + truncated V1 (header claims dim=N but payload bytes < N*4).
    /// Decoder must return nil rather than crash from misaligned header read or
    /// over-reading payload bytes.
    @Test func decodeEmbedding_misalignedTruncatedV1_returnsNil_andDoesNotCrash() {
        // Header declares dim=4 (= 16 bytes payload), but we only ship 1 Float (4 bytes).
        var data = Data("EMB1".utf8)
        var declaredDim = UInt32(4).littleEndian
        data.append(Data(bytes: &declaredDim, count: MemoryLayout<UInt32>.size))
        var oneFloat: Float = 1
        data.append(Data(bytes: &oneFloat, count: MemoryLayout<Float>.size))

        let misalignedData = misaligned(data)

        #expect(misalignedData.count == data.count)
        #expect(Array(misalignedData) == Array(data))

        let decoded = DiaryEntry.decodeEmbeddingVector(misalignedData)
        #expect(decoded == nil)
    }

    /// Defense-in-depth: misaligned V1 with dimension=0 must not crash and
    /// must reject (dim>0 guard in decoder).
    @Test func decodeEmbedding_misalignedV1ZeroDim_returnsNil_andDoesNotCrash() {
        var data = Data("EMB1".utf8)
        var declaredDim = UInt32(0).littleEndian
        data.append(Data(bytes: &declaredDim, count: MemoryLayout<UInt32>.size))

        let misalignedData = misaligned(data)
        #expect(DiaryEntry.decodeEmbeddingVector(misalignedData) == nil)
    }

    /// Defense-in-depth: legacy bare dump whose byte count is not a multiple
    /// of sizeof(Float), with misaligned backing. Must return nil.
    @Test func decodeEmbedding_misalignedLegacyOddByteCount_returnsNil_andDoesNotCrash() {
        // 6 bytes — not a multiple of 4 → legacy path must reject.
        let oddBytes = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        let misalignedData = misaligned(oddBytes)
        #expect(DiaryEntry.decodeEmbeddingVector(misalignedData) == nil)
    }
}

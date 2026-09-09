import Foundation
import XCTest
@testable import InzoneCore

final class DigestsTests: XCTestCase {
    func testKnownSHA256Vectors() {
        XCTAssertEqual(Digests.sha256(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Digests.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Digests.sha256(Data(repeating: 0x61, count: 1_000_000)), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testPaddingBoundaries() {
        let vectors = [
            55: "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
            56: "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
            63: "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
            64: "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
            65: "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
            119: "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb",
            120: "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c",
            127: "c57e9278af78fa3cab38667bef4ce29d783787a2f731d4e12200270f0c32320a",
            128: "6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e",
            129: "c12cb024a2e5551cca0e08fce8f1c5e314555cc3fef6329ee994a3db752166ae",
        ]
        for (count, expected) in vectors {
            XCTAssertEqual(Digests.sha256(Data(repeating: 0x61, count: count)), expected, "Message length: \(count)")
        }
    }

    func testIncrementalUpdatesAcrossBlockBoundaries() {
        let message = Data((0..<4097).map { UInt8($0 % 251) })
        let expected = "a16560d668b843fb3be99ace41dbd18471f342bd3255a1d21204b35e43f74436"
        for chunkSize in [1, 7, 55, 56, 63, 64, 65, 1023] {
            var state = SHA256State()
            for offset in stride(from: 0, to: message.count, by: chunkSize) {
                state.update(message[offset..<min(offset + chunkSize, message.count)])
                state.update(Data())
            }
            XCTAssertEqual(hexadecimal(state.finalize()), expected, "Chunk size: \(chunkSize)")
        }
    }

    func testFinalizingPreservesStateAndDataSliceOffsets() {
        var state = SHA256State()
        state.update(Data("abc".utf8))
        let first = state.finalize()
        XCTAssertEqual(state.finalize(), first)
        state.update(Data("def".utf8))
        XCTAssertEqual(hexadecimal(state.finalize()), "bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721")
        let padded = Data("prefixabcsuffix".utf8)
        XCTAssertEqual(Digests.sha256(padded[6..<9]), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testStreamingFileDigestAcrossOneMiBReads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inzone-digests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload")
        try Data().write(to: file)
        XCTAssertEqual(try Digests.sha256(file: file), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try Digests.sha256(file: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        for (count, expected) in [
            (1_048_641, "b19abfc52a239629bb30725a8a0338dc9bd3aca5b596b905047bf028d4e5ef1b"),
            (2_097_208, "d3cad742ddd868fc70ffbc5117235870df0ed06e0274b8f3d4129cdb2034936a"),
        ] {
            try Data(repeating: 0x61, count: count).write(to: file)
            XCTAssertEqual(try Digests.sha256(file: file), expected)
        }
        XCTAssertThrowsError(try Digests.sha256(file: directory.appendingPathComponent("missing")))
    }

    func testFilterDigestUsesSharedImplementation() {
        let data = Data((0..<1025).map { UInt8($0 % 256) })
        XCTAssertEqual(hexadecimal(FilterCrypto.sha256(data)), Digests.sha256(data))
    }

    private func hexadecimal(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

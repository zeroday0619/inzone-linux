import Foundation

// These primitives preserve the vendor asset format without adding a runtime dependency.
enum FilterCrypto {
    static func sha256(_ data: Data) -> Data {
        Digests.sha256Bytes(data)
    }

    static func md5(_ data: Data) -> Data {
        let message = paddedMessage(data, littleEndianLength: true)
        var digest: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
        for offset in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 16)
            for index in 0..<16 {
                let start = offset + index * 4
                words[index] = UInt32(message[start])
                    | UInt32(message[start + 1]) << 8
                    | UInt32(message[start + 2]) << 16
                    | UInt32(message[start + 3]) << 24
            }
            var state = digest
            for index in 0..<64 {
                let function: UInt32
                let wordIndex: Int
                switch index {
                case 0..<16:
                    function = (state[1] & state[2]) | (~state[1] & state[3])
                    wordIndex = index
                case 16..<32:
                    function = (state[3] & state[1]) | (~state[3] & state[2])
                    wordIndex = (5 * index + 1) % 16
                case 32..<48:
                    function = state[1] ^ state[2] ^ state[3]
                    wordIndex = (3 * index + 5) % 16
                default:
                    function = state[2] ^ (state[1] | ~state[3])
                    wordIndex = (7 * index) % 16
                }
                let sum = state[0] &+ function &+ md5Constants[index] &+ words[wordIndex]
                let next = state[1] &+ rotateLeft(sum, by: md5Shifts[index])
                state = [state[3], next, state[1], state[2]]
            }
            for index in digest.indices {
                digest[index] &+= state[index]
            }
        }
        return Data(digest.flatMap { word in
            [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
             UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)]
        })
    }

    static func aes128CBCDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        try validateAESInputs(data, key: key, iv: iv)
        let roundKeys = expandAESKey(Array(key))
        let input = Array(data)
        var previous = Array(iv)
        var output = Data(capacity: data.count)
        for offset in stride(from: 0, to: input.count, by: 16) {
            let encrypted = Array(input[offset..<(offset + 16)])
            var state = encrypted
            addRoundKey(&state, roundKeys: roundKeys, round: 10)
            for round in stride(from: 9, through: 1, by: -1) {
                shiftRows(&state, inverse: true)
                state = state.map { inverseSubstitution[Int($0)] }
                addRoundKey(&state, roundKeys: roundKeys, round: round)
                mixColumns(&state, inverse: true)
            }
            shiftRows(&state, inverse: true)
            state = state.map { inverseSubstitution[Int($0)] }
            addRoundKey(&state, roundKeys: roundKeys, round: 0)
            for index in state.indices {
                state[index] ^= previous[index]
            }
            output.append(contentsOf: state)
            previous = encrypted
        }
        return output
    }

    static func aes128CBCEncrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        try validateAESInputs(data, key: key, iv: iv)
        let roundKeys = expandAESKey(Array(key))
        let input = Array(data)
        var previous = Array(iv)
        var output = Data(capacity: data.count)
        for offset in stride(from: 0, to: input.count, by: 16) {
            var state = Array(input[offset..<(offset + 16)])
            for index in state.indices {
                state[index] ^= previous[index]
            }
            addRoundKey(&state, roundKeys: roundKeys, round: 0)
            for round in 1..<10 {
                state = state.map { substitution[Int($0)] }
                shiftRows(&state, inverse: false)
                mixColumns(&state, inverse: false)
                addRoundKey(&state, roundKeys: roundKeys, round: round)
            }
            state = state.map { substitution[Int($0)] }
            shiftRows(&state, inverse: false)
            addRoundKey(&state, roundKeys: roundKeys, round: 10)
            output.append(contentsOf: state)
            previous = state
        }
        return output
    }

    private static func paddedMessage(_ data: Data, littleEndianLength: Bool) -> [UInt8] {
        var message = Array(data)
        let bitCount = UInt64(data.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for index in 0..<8 {
            let shift = (littleEndianLength ? index : 7 - index) * 8
            message.append(UInt8(truncatingIfNeeded: bitCount >> shift))
        }
        return message
    }

    private static func rotateLeft(_ value: UInt32, by count: Int) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    private static func validateAESInputs(_ data: Data, key: Data, iv: Data) throws {
        guard key.count == 16 else {
            throw InzoneError.message("AES-128 requires a 16-byte key.")
        }
        guard iv.count == 16 else {
            throw InzoneError.message("AES-CBC requires a 16-byte initialization vector.")
        }
        guard data.count % 16 == 0 else {
            throw InzoneError.message("AES-CBC input must contain complete 16-byte blocks.")
        }
    }

    private static func expandAESKey(_ key: [UInt8]) -> [UInt8] {
        var expanded = key
        var roundConstant: UInt8 = 1
        while expanded.count < 176 {
            var word = Array(expanded.suffix(4))
            if expanded.count % 16 == 0 {
                word = [word[1], word[2], word[3], word[0]].map { substitution[Int($0)] }
                word[0] ^= roundConstant
                roundConstant = multiply(roundConstant, by: 2)
            }
            for index in 0..<4 {
                expanded.append(expanded[expanded.count - 16] ^ word[index])
            }
        }
        return expanded
    }

    private static func addRoundKey(_ state: inout [UInt8], roundKeys: [UInt8], round: Int) {
        for index in state.indices {
            state[index] ^= roundKeys[round * 16 + index]
        }
    }

    private static func shiftRows(_ state: inout [UInt8], inverse: Bool) {
        let original = state
        for row in 1..<4 {
            for column in 0..<4 {
                let sourceColumn = (column + (inverse ? 4 - row : row)) % 4
                state[column * 4 + row] = original[sourceColumn * 4 + row]
            }
        }
    }

    private static func mixColumns(_ state: inout [UInt8], inverse: Bool) {
        let coefficients: [UInt8] = inverse ? [14, 11, 13, 9] : [2, 3, 1, 1]
        for column in 0..<4 {
            let start = column * 4
            let original = Array(state[start..<(start + 4)])
            for row in 0..<4 {
                var value: UInt8 = 0
                for index in 0..<4 {
                    value ^= multiply(original[index], by: coefficients[(index - row + 4) % 4])
                }
                state[start + row] = value
            }
        }
    }

    private static func multiply(_ value: UInt8, by factor: UInt8) -> UInt8 {
        var multiplicand = value
        var multiplier = factor
        var result: UInt8 = 0
        while multiplier != 0 {
            if multiplier & 1 != 0 {
                result ^= multiplicand
            }
            let highBit = multiplicand & 0x80
            multiplicand <<= 1
            if highBit != 0 {
                multiplicand ^= 0x1b
            }
            multiplier >>= 1
        }
        return result
    }

    private static let md5Shifts = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    private static let md5Constants: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    private static let substitution: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]

    private static let inverseSubstitution: [UInt8] = {
        var inverse = [UInt8](repeating: 0, count: 256)
        for (index, value) in substitution.enumerated() {
            inverse[Int(value)] = UInt8(index)
        }
        return inverse
    }()
}

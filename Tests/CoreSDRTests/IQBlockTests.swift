import Testing
@testable import CoreSDR

@Test func normalizedMapsBytesToMinusOneToOne() {
    let block = IQBlock(raw: [0, 255, 128, 127], sampleRate: .rate2_4M,
                        centerFrequency: .mhz(100), sequence: 0, hostTimestamp: 0)
    let n = block.normalized()
    #expect(n.count == 4)
    #expect(abs(n[0] - (-1.0)) < 0.01)      // 0   → ~ -1
    #expect(abs(n[1] - (1.0)) < 0.01)       // 255 → ~ +1
    #expect(abs(n[2]) < 0.01)               // 128 → ~ 0
}

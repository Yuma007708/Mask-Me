import Foundation

/// A single-channel (8-bit) mask: `0` = leave the pixel untouched, `255` =
/// fully mosaic. Packed tightly (`bytesPerRow == width`). Used to drive the
/// flat "background only" mosaic from an externally computed person/background
/// mask. Pure value type so it crosses the Metal availability gate freely.
public struct MaskBuffer: Equatable {
    public let bytes: [UInt8]
    public let width: Int
    public let height: Int

    public init(bytes: [UInt8], width: Int, height: Int) {
        self.bytes = bytes
        self.width = width
        self.height = height
    }
}

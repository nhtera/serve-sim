import Accelerate

/// Whether two frames show the same screen. A phone's frames are decoded from
/// its own lossy USB stream, so a still screen never repeats byte for byte
/// (measured on an iPhone 15 Pro Max home screen: about 3% of bytes differ,
/// by up to 51). Averaging 8×8 cells cancels that noise (cells then differ by
/// at most 22, mostly under 8), while a caret, a digit or a tap highlight —
/// several pixels wide at 3× — moves a cell far more.
enum Still {
    static let cell = 8
    /// Largest cell difference still counted as the same screen.
    static let tolerance = 32

    /// One brightness value per 8×8 cell of a BGRA picture (rows and columns
    /// short of a whole cell are left out).
    static func thumbnail(_ pixels: vImage_Buffer) -> [UInt8] {
        let (w, h) = (Int(pixels.width) / cell, Int(pixels.height) / cell)
        guard w > 0, h > 0, let base = pixels.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var thumb = [UInt8](repeating: 0, count: w * h)
        for ty in 0..<h {
            for tx in 0..<w {
                var sum = 0
                for y in ty * cell..<(ty + 1) * cell {
                    var p = base + y * pixels.rowBytes + tx * cell * 4
                    for _ in 0..<cell {
                        sum += Int(p[0]) + 2 * Int(p[1]) + Int(p[2]) // B, 2G, R
                        p += 4
                    }
                }
                thumb[ty * w + tx] = UInt8(sum / (4 * cell * cell))
            }
        }
        return thumb
    }

    static func looksSame(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > tolerance { return false }
        return true
    }
}

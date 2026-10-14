/// The pixel mapping between the 400x240 eye images and the encoded frames.
///
/// Each eye image is rotated 90° clockwise into a 240-wide x 400-tall block. With the
/// `.stacked240x800` layout the left block occupies rows 0..399 and the right rows 400..799;
/// with `.alternating240x400` each encoded frame is one block. Mirrors the `s3ds_rotate_stack`
/// Metal kernel; use it for CPU-side tooling and tests.
public enum RotationMapping {
    public static let eyeWidth = 400
    public static let eyeHeight = 240
    /// Width of every encoded frame.
    public static let frameWidth = 240
    /// Height of a stacked (240x800) frame.
    public static let frameHeight = 800

    /// The eye image pixel shown at stacked-frame pixel `(column, row)` (240x800 layout).
    /// - Precondition: `0 <= column < 240`, `0 <= row < 800`.
    public static func eyePixel(forFrameColumn column: Int, row: Int) -> (eye: S3DSEye, x: Int, y: Int) {
        precondition((0..<frameWidth).contains(column) && (0..<frameHeight).contains(row))
        let eye: S3DSEye = row < eyeWidth ? .left : .right
        return (eye, row % eyeWidth, (eyeHeight - 1) - column)
    }

    /// The stacked-frame pixel that shows eye image pixel `(x, y)` (inverse of `eyePixel`).
    /// - Precondition: `0 <= x < 400`, `0 <= y < 240`.
    public static func framePixel(eye: S3DSEye, x: Int, y: Int) -> (column: Int, row: Int) {
        let p = blockPixel(x: x, y: y)
        return (p.column, p.row + (eye == .left ? 0 : eyeWidth))
    }

    /// The pixel `(x, y)` of an eye image inside its own rotated 240x400 block (one alternating
    /// frame): `column = 239 - y`, `row = x`.
    public static func blockPixel(x: Int, y: Int) -> (column: Int, row: Int) {
        precondition((0..<eyeWidth).contains(x) && (0..<eyeHeight).contains(y))
        return ((eyeHeight - 1) - y, x)
    }

    /// The eye image pixel shown at pixel `(column, row)` of a 240x400 block (one alternating frame):
    /// `x = row`, `y = 239 - column`.
    public static func eyePixel(forBlockColumn column: Int, row: Int) -> (x: Int, y: Int) {
        precondition((0..<frameWidth).contains(column) && (0..<eyeWidth).contains(row))
        return (row, (eyeHeight - 1) - column)
    }
}

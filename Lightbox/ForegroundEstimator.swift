//
//  ForegroundEstimator.swift
//  Lightbox
//
//  Removes background colour that bleeds into soft edges (hair, motion and focus blur), which otherwise shows up as a
//  coloured outline once the background is gone. Blur-fusion foreground estimation (Forest et al., "Approximate Fast
//  Foreground Colour Estimation", ICIP 2021), as used by BiRefNet's refine_foreground: two passes, a wide one that
//  estimates local foreground/background colours and a narrow one that refines them. Runs on the CPU with Accelerate
//  (box blurs are parallel running sums, O(1) per pixel whatever the radius; the arithmetic is vDSP), so a 24 MP photo takes well under a second.
//

import Accelerate


nonisolated enum ForegroundEstimator {
    /// `rgb`: three planes in 0…1, `alpha`: one plane in 0…1, all `width × height`. Returns the foreground colour planes.
    static func estimate(rgb: [[Float]], alpha: [Float], width: Int, height: Int) -> [[Float]] {
        // The reference radii (90, 6) are for ~1 MP inputs; scale them with the photo.
        let scale = max(1, Double(max(width, height)) / 1024)
        let wide = odd(90 * scale), narrow = odd(6 * scale)
        let (f1, b1) = pass(image: rgb, foreground: rgb, background: rgb, alpha: alpha, width: width, height: height, radius: wide)
        return pass(image: rgb, foreground: f1, background: b1, alpha: alpha, width: width, height: height, radius: narrow).foreground
    }

    private static func pass(image: [[Float]], foreground: [[Float]], background: [[Float]], alpha: [Float],
                             width: Int, height: Int, radius: Int) -> (foreground: [[Float]], background: [[Float]]) {
        let n = alpha.count
        let invAlpha = vDSP.add(1, vDSP.negative(alpha))                       // 1 - a
        let blurredAlpha = vDSP.add(1e-5, blur(alpha, width, height, radius))   // blur(a) + eps
        let blurredInv = vDSP.add(1e-5, blur(invAlpha, width, height, radius))  // blur(1 - a) + eps

        var outF: [[Float]] = [], outB: [[Float]] = []
        for c in 0..<3 {
            let fg = vDSP.divide(blur(vDSP.multiply(foreground[c], alpha), width, height, radius), blurredAlpha)
            let bg = vDSP.divide(blur(vDSP.multiply(background[c], invAlpha), width, height, radius), blurredInv)
            // F = fg + a * (I - a*fg - (1-a)*bg)
            var residual = vDSP.subtract(image[c], vDSP.multiply(alpha, fg))
            residual = vDSP.subtract(residual, vDSP.multiply(invAlpha, bg))
            var f = vDSP.add(fg, vDSP.multiply(alpha, residual))
            vDSP.clip(f, to: 0...1, result: &f)
            precondition(f.count == n)
            outF.append(f)
            outB.append(bg)
        }
        return (outF, outB)
    }

    /// Separable box blur, applied twice (≈ tent filter, avoids box artefacts at large radii). Edges are extended.
    private static func blur(_ plane: [Float], _ width: Int, _ height: Int, _ kernel: Int) -> [Float] {
        var a = plane
        var b = [Float](repeating: 0, count: plane.count)
        let r = kernel / 2
        for _ in 0..<2 {
            boxRows(a, into: &b, width: width, height: height, radius: r)
            vDSP_mtrans(b, 1, &a, 1, vDSP_Length(width), vDSP_Length(height))    // a = bᵀ (height × width → width × height)
            boxRows(a, into: &b, width: height, height: width, radius: r)
            vDSP_mtrans(b, 1, &a, 1, vDSP_Length(height), vDSP_Length(width))
        }
        return a
    }

    /// Running-sum box filter along each row: O(1) per pixel whatever the radius; rows run in parallel.
    private static func boxRows(_ src: [Float], into dst: inout [Float], width: Int, height: Int, radius r: Int) {
        let norm = 1 / Double(2 * r + 1)
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                nonisolated(unsafe) let (sp, dp) = (s.baseAddress!, d.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let row = sp + y * width, out = dp + y * width
                    var acc = 0.0
                    for i in -r...r { acc += Double(row[min(max(i, 0), width - 1)]) }
                    for x in 0..<width {
                        out[x] = Float(acc * norm)
                        acc += Double(row[min(x + r + 1, width - 1)]) - Double(row[max(x - r, 0)])
                    }
                }
            }
        }
    }

    private static func odd(_ value: Double) -> Int {
        let v = Int(value.rounded())
        return v.isMultiple(of: 2) ? v + 1 : v
    }
}

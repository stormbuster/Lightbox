//
//  PSDWriter.swift
//  Lightbox
//
//  Minimal layered Photoshop (.psd, version 1) writer: 8-bit RGB layers, optional layer masks, RLE (PackBits)
//  compression, embedded ICC profile and a flattened composite for previews. Opens in Photoshop, Affinity, Pixelmator
//  and Photopea. Spec: https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/
//

import Foundation


nonisolated enum PSDWriter {
    struct Layer {
        var name: String
        /// R, G, B planes, `width × height` bytes each.
        var rgb: [[UInt8]]
        /// Layer mask (255 = shown), editable in the target app; nil for none.
        var mask: [UInt8]?
        var hidden = false
    }

    /// `layers` are bottom to top; `composite` is the flattened R, G, B image shown by previews.
    static func data(width: Int, height: Int, layers: [Layer], composite: [[UInt8]], iccProfile: Data?) -> Data {
        var out = BigEndian()

        // Header
        out.append("8BPS"); out.u16(1); out.zeros(6)
        out.u16(3); out.u32(height); out.u32(width); out.u16(8); out.u16(3)   // 3 channels, 8 bit, RGB

        // Colour mode data
        out.u32(0)

        // Image resources: the ICC profile (1039)
        var resources = BigEndian()
        if let icc = iccProfile {
            resources.append("8BIM"); resources.u16(1039); resources.u16(0)   // id, empty Pascal name (padded to 2)
            resources.u32(icc.count); resources.bytes(icc)
            if icc.count % 2 == 1 { resources.zeros(1) }
        }
        out.u32(resources.data.count); out.bytes(resources.data)

        // Layer and mask information
        let opaque = [UInt8](repeating: 255, count: width * height)
        var records = BigEndian(), channels = BigEndian()
        for layer in layers {
            var planes: [(id: Int16, data: [UInt8])] = [(-1, opaque), (0, layer.rgb[0]), (1, layer.rgb[1]), (2, layer.rgb[2])]
            if let mask = layer.mask { planes.append((-2, mask)) }

            records.i32(0); records.i32(0); records.i32(height); records.i32(width)
            records.u16(planes.count)
            var encoded: [Data] = []
            for plane in planes {
                let channel = rle(plane.data, width: width, height: height)
                encoded.append(channel)
                records.i16(plane.id); records.u32(2 + channel.count)
            }
            records.append("8BIM"); records.append("norm")
            records.u8(255); records.u8(0); records.u8(layer.hidden ? 0x02 : 0x00); records.u8(0)   // opacity, clipping, flags

            var extra = BigEndian()
            if layer.mask != nil {
                extra.u32(20)
                extra.i32(0); extra.i32(0); extra.i32(height); extra.i32(width)
                extra.u8(0); extra.u8(0); extra.zeros(2)                       // default colour, flags, padding
            } else {
                extra.u32(0)
            }
            extra.u32(0)                                                        // blending ranges
            extra.pascal(layer.name, multiple: 4)
            extra.append("8BIM"); extra.append("luni")                         // Unicode name
            let utf16 = Array(layer.name.utf16)
            extra.u32(4 + utf16.count * 2 + (utf16.count % 2 == 1 ? 2 : 0))
            extra.u32(utf16.count); utf16.forEach { extra.u16(Int($0)) }
            if utf16.count % 2 == 1 { extra.zeros(2) }
            records.u32(extra.data.count); records.bytes(extra.data)

            for channel in encoded { channels.u16(1); channels.bytes(channel) }   // compression 1 = RLE
        }
        var layerInfo = BigEndian()
        layerInfo.i16(Int16(layers.count)); layerInfo.bytes(records.data); layerInfo.bytes(channels.data)
        if layerInfo.data.count % 4 != 0 { layerInfo.zeros(4 - layerInfo.data.count % 4) }

        out.u32(4 + layerInfo.data.count + 4)
        out.u32(layerInfo.data.count); out.bytes(layerInfo.data)
        out.u32(0)                                                              // global layer mask info

        // Composite image data: RLE, all row byte counts first, then the rows, channel by channel
        out.u16(1)
        let rows = composite.map { rleRows($0, width: width, height: height) }
        for channel in rows { for row in channel { out.u16(row.count) } }
        for channel in rows { for row in channel { out.bytes(row) } }
        return out.data
    }

    /// One layer channel: byte counts per row, then the PackBits rows.
    private static func rle(_ plane: [UInt8], width: Int, height: Int) -> Data {
        let rows = rleRows(plane, width: width, height: height)
        var out = BigEndian()
        for row in rows { out.u16(row.count) }
        for row in rows { out.bytes(row) }
        return out.data
    }

    private static func rleRows(_ plane: [UInt8], width: Int, height: Int) -> [Data] {
        var rows = [Data](repeating: Data(), count: height)
        plane.withUnsafeBufferPointer { buffer in
            nonisolated(unsafe) let base = buffer.baseAddress!
            rows.withUnsafeMutableBufferPointer { output in
                nonisolated(unsafe) let out = output.baseAddress!
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    out[y] = packBits(UnsafeBufferPointer(start: base + y * width, count: width))
                }
            }
        }
        return rows
    }

    /// PackBits: runs of 3+ equal bytes as (1 - n, byte), everything else as literals of up to 128 bytes.
    private static func packBits(_ row: UnsafeBufferPointer<UInt8>) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(row.count / 2)
        let n = row.count
        var i = 0
        while i < n {
            var j = i + 1
            while j < n && j - i < 128 && row[j] == row[i] { j += 1 }
            if j - i >= 3 {
                out.append(UInt8(bitPattern: Int8(1 - (j - i)))); out.append(row[i])
                i = j
                continue
            }
            var k = i
            while k < n && k - i < 128 {
                if k + 2 < n && row[k] == row[k + 1] && row[k] == row[k + 2] { break }
                k += 1
            }
            out.append(UInt8(k - i - 1)); out.append(contentsOf: row[i..<k])
            i = k
        }
        return Data(out)
    }
}


nonisolated private struct BigEndian {
    var data = Data()
    mutating func u8(_ v: Int) { data.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).bigEndian; data.append(Data(bytes: &x, count: 2)) }
    mutating func i16(_ v: Int16) { var x = v.bigEndian; data.append(Data(bytes: &x, count: 2)) }
    mutating func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).bigEndian; data.append(Data(bytes: &x, count: 4)) }
    mutating func i32(_ v: Int) { var x = Int32(truncatingIfNeeded: v).bigEndian; data.append(Data(bytes: &x, count: 4)) }
    mutating func zeros(_ n: Int) { data.append(Data(count: n)) }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func append(_ s: String) { data.append(s.data(using: .ascii)!) }
    /// Pascal string (length byte + MacRoman/ASCII), padded so the total is a multiple of `multiple`.
    mutating func pascal(_ s: String, multiple: Int) {
        let bytes = Array((s.data(using: .macOSRoman, allowLossyConversion: true) ?? Data()).prefix(255))
        u8(bytes.count); data.append(contentsOf: bytes)
        let total = 1 + bytes.count
        if total % multiple != 0 { zeros(multiple - total % multiple) }
    }
}

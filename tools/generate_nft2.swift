#!/usr/bin/env xcrun swift

import AppKit
import CoreText
import Foundation

struct Config {
    let fontNames: [String]
    let fontSize: CGFloat
    let outputPath: String
    let charsetPath: String
}

struct GlyphRecord {
    let character: UInt16
    let glyphWidth: UInt8
    let spacingLeft: Int8
    let spacingRight: Int8
    let glyphHeight: UInt8
    let spacingTop: Int8
    let bitmap: [UInt8]
}

func align4(_ value: Int) -> Int {
    (value + 3) & ~3
}

func packGlyphBitmap(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
    var packed = [UInt8]()
    packed.reserveCapacity(((width + 1) / 2) * height)
    for y in 0 ..< height {
        for x in stride(from: 0, to: width, by: 2) {
            let left = pixels[y * width + x] & 0x0F
            let right = x + 1 < width ? (pixels[y * width + x + 1] & 0x0F) : 0
            packed.append(left | (right << 4))
        }
    }
    return packed
}

func splitIntoRanges(_ chars: [UInt16]) -> [[UInt16]] {
    guard let first = chars.first else { return [] }
    var ranges: [[UInt16]] = [[first]]
    for ch in chars.dropFirst() {
        if let last = ranges[ranges.count - 1].last, ch == last + 1 {
            ranges[ranges.count - 1].append(ch)
        } else {
            ranges.append([ch])
        }
    }
    return ranges
}

func encodeUTF16BMP(_ string: String) -> [UInt16] {
    var result: [UInt16] = []
    for scalar in string.unicodeScalars {
        if scalar.value <= 0xFFFF {
            result.append(UInt16(scalar.value))
        }
    }
    return result
}

func loadCharacters(from path: String) throws -> [UInt16] {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    let chars = Array(Set(encodeUTF16BMP(content))).sorted()
    return chars.filter { $0 != 0 }
}

func createFont(name: String, size: CGFloat) -> CTFont {
    if let nsFont = NSFont(name: name, size: size) {
        return nsFont as CTFont
    }
    return CTFontCreateWithName(name as CFString, size, nil)
}

func renderGlyph(fonts: [CTFont], character: UInt16, lineHeight: Int, ascent: Int) -> GlyphRecord? {
    var utf16 = character
    var glyph = CGGlyph()
    var selectedFont: CTFont?
    for font in fonts {
        if CTFontGetGlyphsForCharacters(font, &utf16, &glyph, 1), glyph != 0 {
            selectedFont = font
            break
        }
    }
    guard let font = selectedFont else { return nil }

    var cgGlyph = glyph
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &cgGlyph, &advance, 1)

    var bounds = CGRect.zero
    CTFontGetBoundingRectsForGlyphs(font, .horizontal, &cgGlyph, &bounds, 1)
    if bounds.isNull || bounds.isInfinite {
        bounds = .zero
    }

    let spacingLeft = Int8(clamping: Int(floor(bounds.minX)))
    let glyphWidth = max(1, Int(ceil(bounds.maxX)) - Int(floor(bounds.minX)))
    let spacingRight = Int8(clamping: Int(round(advance.width)) - Int(spacingLeft) - glyphWidth)
    let spacingTop = Int8(clamping: Int(floor(CGFloat(ascent) - ceil(bounds.maxY))))
    let glyphHeight = max(1, Int(ceil(bounds.maxY)) - Int(floor(bounds.minY)))

    let bytesPerRow = glyphWidth
    var raw = [UInt8](repeating: 0, count: glyphWidth * glyphHeight)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard let context = CGContext(
        data: &raw,
        width: glyphWidth,
        height: glyphHeight,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else {
        return nil
    }

    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: glyphWidth, height: glyphHeight))
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.setFillColor(gray: 1, alpha: 1)
    context.translateBy(x: -floor(bounds.minX), y: -floor(bounds.minY))
    if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
        context.addPath(path)
        context.fillPath()
    }

    var pixels = [UInt8](repeating: 0, count: glyphWidth * glyphHeight)
    for y in 0 ..< glyphHeight {
        for x in 0 ..< glyphWidth {
            let src = raw[y * glyphWidth + x]
            pixels[y * glyphWidth + x] = UInt8(min(15, Int((UInt16(src) * 15 + 127) / 255)))
        }
    }

    return GlyphRecord(
        character: character,
        glyphWidth: UInt8(clamping: glyphWidth),
        spacingLeft: spacingLeft,
        spacingRight: spacingRight,
        glyphHeight: UInt8(clamping: glyphHeight),
        spacingTop: spacingTop,
        bitmap: packGlyphBitmap(pixels, width: glyphWidth, height: glyphHeight)
    )
}

func writeUInt32(_ value: UInt32, to data: inout Data) {
    var v = value.littleEndian
    data.append(Data(bytes: &v, count: 4))
}

func writeUInt16(_ value: UInt16, to data: inout Data) {
    var v = value.littleEndian
    data.append(Data(bytes: &v, count: 2))
}

func writeInt8(_ value: Int8, to data: inout Data) {
    var v = value
    data.append(Data(bytes: &v, count: 1))
}

func generate(config: Config) throws {
    let chars = try loadCharacters(from: config.charsetPath)
    let fonts = config.fontNames.map { createFont(name: $0, size: config.fontSize) }
    let ascent = fonts.map { Int(ceil(CTFontGetAscent($0))) }.max() ?? 0
    let descent = fonts.map { Int(ceil(CTFontGetDescent($0))) }.max() ?? 0
    let lineHeight = max(1, ascent + descent)

    var glyphs: [GlyphRecord] = []
    glyphs.reserveCapacity(chars.count + 1)

    let missingGlyph = GlyphRecord(
        character: 0,
        glyphWidth: 1,
        spacingLeft: 0,
        spacingRight: 0,
        glyphHeight: 1,
        spacingTop: 0,
        bitmap: [0]
    )
    glyphs.append(missingGlyph)

    var charToGlyph: [UInt16: UInt16] = [:]
    for ch in chars {
        if let record = renderGlyph(fonts: fonts, character: ch, lineHeight: lineHeight, ascent: ascent) {
            charToGlyph[ch] = UInt16(glyphs.count)
            glyphs.append(record)
        }
    }

    let mappedChars = charToGlyph.keys.sorted()
    let ranges = splitIntoRanges(mappedChars)

    let headerSize = 20
    let glyphInfoOffset = headerSize
    let glyphInfoSize = glyphs.count * 8
    let charMapOffset = align4(glyphInfoOffset + glyphInfoSize)
    var charMapData = Data()
    charMapData.reserveCapacity(ranges.count * 16)
    for range in ranges {
        writeUInt16(UInt16(range.count), to: &charMapData)
        writeUInt16(range.first!, to: &charMapData)
        for ch in range {
            writeUInt16(charToGlyph[ch]!, to: &charMapData)
        }
    }
    writeUInt16(0, to: &charMapData)
    writeUInt16(0, to: &charMapData)

    let glyphDataOffset = align4(charMapOffset + charMapData.count)
    var glyphData = Data()
    glyphData.reserveCapacity(glyphs.reduce(0) { $0 + $1.bitmap.count + 4 })

    var glyphEntries = Data()
    glyphEntries.reserveCapacity(glyphInfoSize)
    for glyph in glyphs {
        let dataOffset = UInt32(glyphData.count)
        let packedOffsetWidth = dataOffset | (UInt32(glyph.glyphWidth) << 24)
        writeUInt32(packedOffsetWidth, to: &glyphEntries)
        writeInt8(glyph.spacingLeft, to: &glyphEntries)
        writeInt8(glyph.spacingRight, to: &glyphEntries)
        glyphEntries.append(glyph.glyphHeight)
        writeInt8(glyph.spacingTop, to: &glyphEntries)
        glyphData.append(glyph.bitmap, count: glyph.bitmap.count)
        while (glyphData.count & 3) != 0 {
            glyphData.append(0)
        }
    }

    var output = Data()
    writeUInt32(0x3254464E, to: &output)
    writeUInt32(UInt32(glyphInfoOffset), to: &output)
    writeUInt32(UInt32(charMapOffset), to: &output)
    writeUInt32(UInt32(glyphDataOffset), to: &output)
    output.append(UInt8(clamping: ascent))
    output.append(UInt8(clamping: descent))
    writeUInt16(UInt16(glyphs.count), to: &output)
    output.append(glyphEntries)
    while output.count < charMapOffset {
        output.append(0)
    }
    output.append(charMapData)
    while output.count < glyphDataOffset {
        output.append(0)
    }
    output.append(glyphData)

    try output.write(to: URL(fileURLWithPath: config.outputPath))
}

func usage() {
    fputs("usage: generate_nft2.swift <font-name[,fallback-font...]> <font-size> <charset.txt> <output.nft2>\n", stderr)
}

if CommandLine.arguments.count != 5 {
    usage()
    exit(1)
}

let config = Config(
    fontNames: CommandLine.arguments[1].split(separator: ",").map(String.init),
    fontSize: CGFloat(Double(CommandLine.arguments[2]) ?? 0),
    outputPath: CommandLine.arguments[4],
    charsetPath: CommandLine.arguments[3]
)

try generate(config: config)

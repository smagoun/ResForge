import AppKit
import RFSupport

// Decoder for `CvPc` resource used in classic MacOS Civilization 1
// (Editing not supported)
//
// Derived from gif_convert.cpp by Honza Havlicek, ported to Swift
// with help from Claude.ai

/*
 * Demostration source for various formats used in Civilization I for Windows.
 * Copyright (c) 2008, by Honza Havlicek
 *
 * Contact: havlicek.honza@gmail.com
 *
 * Permission is given by the author to freely redistribute and include
 * this code in any program as long as this credit is given where due.
 *
 * It also took ages to decode, so if you like this or use this,
 * please send me a note.
 *
 * Release notes: This file contains a decoder and encoder routines for GIF files
 * used by game Civilization 1. The GIF files are not the standard GIF files
 * although they use LZW compression with variable bitwidth of bitcode,
 * reset of dictionary bitcode and done bitcode.
 *
 * The structure of file is not properly defined in structure, but it should
 * be easy to recognize by researching gif2palette_image()
 */

let BITCODE_WIDTH_MAX = 11  // Max observed value
let bytesPerPixel = 3  // RGB (use 4 for RGBA)
let bitsPerSample = 8  // 8 bits per color channel (R, G, B)

struct Color {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
}

struct DictionaryEntry {
    var colorIndex: UInt8 = 0
    var prefixBitcode: Int = -1
    var length: Int = 0
}

func expandDictionaryEntry(_ bitcode: Int, dictionary: [DictionaryEntry]) -> [UInt8] {
    var sequence: [UInt8] = []
    sequence.reserveCapacity(dictionary[bitcode].length)
    var currentBitcode = bitcode
    while currentBitcode != -1 {
        sequence.append(dictionary[currentBitcode].colorIndex)
        currentBitcode = dictionary[currentBitcode].prefixBitcode
    }
    return sequence.reversed()
}

struct PaletteImage {
    var width: Int
    var height: Int
    var paletteSize: Int
    var palette: [Color]
    var data: [UInt8]      // Decoded image. Each element is an index into the palette
}

enum CvPcError: Error {
    case invalidHeader
    case invalidColorIndex(colorIndex: Int)
    case invalidDimensions(imageWidth: Int, imageHeight: Int)
    case invalidPaletteSize(paletteSize: Int)
    case truncatedPaletteColor
    case bitmapCreationFailed
    case invalidBitmapData(expected: Int, actual: Int)  // Mismatch between expected and actual bitmap data size
    case incompleteImage(expected: Int, actual: Int)    // Not enough pixels generated
    case doneBitcodeNotFound
    case invalidBitcodeSequence(bitcode: Int, nextBitcode: Int)
    case invalidBitcodeWidth(width: Int)
    case pictureOverflow
}

/* File format is (big-endian):
 * 0x00 - width (2 bytes)
 * 0x02 - height (2 bytes)
 * 0x04 - initial bitcode width (2-11) (max value observed is 8)
 * 0x05 - palette size - 1
 * 0x06 - palette data (3 byte r/g/b tuple)
 * 0xnn - LZW-and-RLE compressed image data
 */
struct CvPc {
    var imageRep: NSBitmapImageRep
    
    init?(_ reader: BinaryDataReader) throws {
        let compressed = try reader.readData(length: reader.bytesRemaining)
        guard let imgData = try decodeImage(data: compressed) else {
            return nil
        }
        guard let imageRep = try createImageRepFromPaletteImage(from: imgData) else {
            return nil
        }
        self.imageRep = imageRep
    }

    static func rep(_ data: Data) -> NSBitmapImageRep? {
        let reader = BinaryDataReader(data, bigEndian: true)
        return try? Self(reader)?.imageRep
    }
}


func createImageRepFromPaletteImage(from paletteImage: PaletteImage) throws -> NSBitmapImageRep? {
    let width = Int(paletteImage.width)
    let height = Int(paletteImage.height)

    guard width > 0, height > 0 else {
        throw CvPcError.invalidDimensions(imageWidth: width, imageHeight: height)
    }
    
    // Create bitmap with RGB color space
    guard let bitmapRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: bitsPerSample,
        samplesPerPixel: bytesPerPixel,
        hasAlpha: false,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: width * bytesPerPixel,
        bitsPerPixel: bitsPerSample * bytesPerPixel
    ) else {
        throw CvPcError.bitmapCreationFailed
    }
    
    // Get pointer to the bitmap data
    let bitmapSize = bitmapRep.bytesPerRow * bitmapRep.pixelsHigh
    guard let bitmapData = bitmapRep.bitmapData, bitmapSize >= width * height * bytesPerPixel else {
        throw CvPcError.invalidBitmapData(expected: width * height * bytesPerPixel, actual: bitmapSize)
    }
    
    // Fill in the pixel data from the palette
    for pixelIndex in 0..<(width * height) {
        let colorIndex = Int(paletteImage.data[pixelIndex])

        guard colorIndex < paletteImage.palette.count else {
            throw CvPcError.invalidColorIndex(colorIndex: colorIndex)
        }

        let color = paletteImage.palette[colorIndex]
        let offset = pixelIndex * bytesPerPixel
        
        bitmapData[offset] = color.red
        bitmapData[offset + 1] = color.green
        bitmapData[offset + 2] = color.blue
    }
    
    return bitmapRep
}


class BitReader {
    private let data: ArraySlice<UInt8>
    private var position: Int
    private var dataChunkLength: Int = 0
    private var readBits: UInt32 = 0
    private var numberOfReadBits: Int = 0
    
    init(data: ArraySlice<UInt8>) {
        self.data = data
        self.position = data.startIndex
    }
    
    func readByte() -> UInt8? {
        guard position < data.endIndex else {
            return nil
        }
        let byte = data[position]
        position += 1
        return byte
    }
    
    // Read the specified number of bytes and return them as an array/
    func readBytes(count: Int) -> [UInt8]? {
        guard count > 0, data.endIndex - position >= count else { return nil }
        let ret = Array(data[position..<position+count])
        position += count
        return ret
    }

    // Get the next bitcode of the specified width from the bit stream
    func getBitcode(bitcodeWidth: Int) -> Int? {
        let requiredBits = bitcodeWidth + 1

        while numberOfReadBits < requiredBits {
            if dataChunkLength == 0 {
                guard let chunkSize = readByte() else { return nil }
                dataChunkLength = Int(chunkSize)
                guard dataChunkLength > 0 else { return nil }
            } else {
                guard let byte = readByte() else { return nil }
                readBits |= UInt32(byte) << numberOfReadBits
                numberOfReadBits += 8
                
                dataChunkLength -= 1
            }
        }
        
        // Get bitcode from readBits buffer
        let bitcodeMask = (1 << requiredBits) - 1
        let bitcode = Int(readBits & UInt32(bitcodeMask))
        
        // Empty bits we have used in bitcode from readBits buffer
        readBits >>= requiredBits
        numberOfReadBits -= requiredBits
        
        return bitcode
    }
}

// Decodes a compressed image into a PaletteImage
func decodeImage<T: Collection>(data: T) throws -> PaletteImage? where T.Element == UInt8 {
    let byteArray = ArraySlice(data)
    let bitReader = BitReader(data: byteArray)
    
    // Read 6-byte image header; values are big-endian
    guard let header = bitReader.readBytes(count: 6) else {
        throw CvPcError.invalidHeader
    }
    let imageWidth: Int = Int(header[0]) << 8 | Int(header[1])
    let imageHeight: Int = Int(header[2]) << 8 | Int(header[3])
    let origBitcodeWidth: Int = Int(header[4])
    let paletteSize: Int = Int(header[5]) + 1

    // Max dimensions are arbitrary and based on expected image sizes
    guard (1...2048).contains(imageWidth), (1...2048).contains(imageHeight) else {
        throw CvPcError.invalidDimensions(imageWidth: imageWidth, imageHeight: imageHeight)
    }
    // Max observed value is 8; bitcodes within the image can go up to 11 bits
    // Max value is 8 because dictionary is loaded with initial
    // palette, which is up to 2^8 entries
    guard (2...8).contains(origBitcodeWidth) else {
        throw CvPcError.invalidBitcodeWidth(width: origBitcodeWidth)
    }
    guard (1...256).contains(paletteSize) else {
        throw CvPcError.invalidPaletteSize(paletteSize: paletteSize)
    }

    var palette: [Color] = [Color]()
    palette.reserveCapacity(paletteSize)
    guard let paletteData = bitReader.readBytes(count: paletteSize * bytesPerPixel) else {
        throw CvPcError.truncatedPaletteColor
    }
    var offset = 0
    for i in 0..<paletteSize {
        palette.append(
            Color(
                red:   paletteData[offset], 
                green: paletteData[offset + 1],
                blue:  paletteData[offset + 2]))
        offset += bytesPerPixel
    }
    
    // Initialize decompression constants
    let resetDictBitcode = 1 << origBitcodeWidth
    let doneBitcode = (1 << origBitcodeWidth) + 1
    let origBitcodeMask = (2 << origBitcodeWidth) - 1
    var prevBitcode = resetDictBitcode
    var nextBitcode = doneBitcode + 1
    var bitcodeWidth = origBitcodeWidth
    var bitcodeMask = origBitcodeMask
    var foundDoneBitcode = false
    
    var picture = [UInt8](repeating: 0, count: Int(imageWidth) * Int(imageHeight))
    var pictureCur = 0
    
    // Fill in dictionary
    // Bitcodes are at most BITCODE_WIDTH_MAX (11) bits
    // We can read BITCODE_WIDTH_MAX+1 bits
    let dictionarySize = (1 << (BITCODE_WIDTH_MAX + 1))
    var dictionary = [DictionaryEntry](repeating: DictionaryEntry(), count: dictionarySize)
    
    // Fill table with initial bitcodes
    for bitcode in 0..<(1 << origBitcodeWidth) {
        dictionary[bitcode].colorIndex = UInt8(bitcode)
        dictionary[bitcode].prefixBitcode = -1
        dictionary[bitcode].length = 1
    }
    
    // Main loop
    while let bitcode = bitReader.getBitcode(bitcodeWidth: bitcodeWidth) {
        
        // Handle Done
        if bitcode == doneBitcode {
            foundDoneBitcode = true
            break
        }
        
        // Handle reset
        if bitcode == resetDictBitcode {
            prevBitcode = resetDictBitcode
            nextBitcode = doneBitcode + 1
            bitcodeWidth = origBitcodeWidth
            bitcodeMask = origBitcodeMask
            continue
        }
        
        // First case: immediately after reset
        if prevBitcode == resetDictBitcode {
            guard pictureCur < picture.count else {
                throw CvPcError.pictureOverflow
            }
            guard (0..<(1 << origBitcodeWidth)).contains(bitcode),
                    bitcode < paletteSize else {
                throw CvPcError.invalidBitcodeSequence(
                    bitcode: bitcode,
                    nextBitcode: nextBitcode
                )
            }
            prevBitcode = bitcode
            picture[pictureCur] = dictionary[bitcode].colorIndex
            pictureCur += 1
            continue
        }
        
        // Resolve the current sequence before adding the next dictionary entry.
        let sequence: [UInt8]
        if bitcode < nextBitcode {
            sequence = expandDictionaryEntry(bitcode, dictionary: dictionary)
        } else if bitcode == nextBitcode {
            let previousSequence = expandDictionaryEntry(prevBitcode, dictionary: dictionary)
            sequence = previousSequence + [previousSequence[0]]
        } else {
            throw CvPcError.invalidBitcodeSequence(bitcode: bitcode, nextBitcode: nextBitcode)
        }

        guard pictureCur + sequence.count <= picture.count else {
            throw CvPcError.pictureOverflow
        }
        for colorIndex in sequence {
            picture[pictureCur] = colorIndex
            pictureCur += 1
        }

        // The new entry is previous_sequence + current_sequence[0].
        let firstColor = sequence[0]
        dictionary[nextBitcode].length = dictionary[prevBitcode].length + 1
        dictionary[nextBitcode].prefixBitcode = prevBitcode
        dictionary[nextBitcode].colorIndex = firstColor
        prevBitcode = bitcode
        
        nextBitcode += 1
        if nextBitcode > bitcodeMask {
            if bitcodeWidth < BITCODE_WIDTH_MAX {
                bitcodeWidth += 1
                bitcodeMask = (bitcodeMask << 1) | 0x1
            } else {
                // Not an error, just can't resize further
            }
        }
    }

    guard foundDoneBitcode else {
        throw CvPcError.doneBitcodeNotFound
    }
    
    // Did we generate enough pixels?
    guard pictureCur == picture.count else {
        throw CvPcError.incompleteImage(
            expected: picture.count,
            actual: pictureCur
        )
    }
    
    // Return the image
    return PaletteImage(
        width: imageWidth,
        height: imageHeight,
        paletteSize: paletteSize,
        palette: palette,
        data: picture
    )
}

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

let DEBUG = 0
let BITCODE_WIDTH_MAX = 11
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

struct PaletteImage {
    var width: Int
    var height: Int
    var paletteSize: Int
    var palette: [Color]
    var data: [UInt8]      // Decoded image. Each element is an index into the palette
}

enum CvPcError: Error {
    case invalidHeader
    case invalidImageData
    case invalidColorIndex(colorIndex: Int)
    case invalidDimensions(imageWidth: Int, imageHeight: Int)
    case invalidPaletteSize(paletteSize: Int)
    case truncatedPaletteColor
    case bitmapCreationFailed
    case invalidBitmapData(expected: Int, actual: Int)
    case doneBitcodeNotFound
    case invalidBitcodeSequence(bitcode: Int, nextBitcode: Int)
    case invalidBitcodeWidth(width: Int)
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
    private var data: ArraySlice<UInt8>
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
                
                if DEBUG >= 1 {
                    print("!! new chunk of data, size 0x\(String(format: "%02X", dataChunkLength))")
                }
                
                guard dataChunkLength > 0 else {
                    if DEBUG >= 1 {
                        print("******Double data_chunk zero")
                    }
                    return 0
                }
            } else {
                guard let byte = readByte() else { return nil }
                readBits |= UInt32(byte) << numberOfReadBits
                numberOfReadBits += 8
                
                if DEBUG >= 2 {
                    print("!! (0x\(String(format: "%02X", dataChunkLength)))read compressed byte 0x\(String(format: "%02X", byte))")
                }
                dataChunkLength -= 1
            }
        }
        
        // Get bitcode from readBits buffer
        let bitcodeMask = (1 << requiredBits) - 1
        let bitcode = Int(readBits & UInt32(bitcodeMask))
        
        if DEBUG >= 2 {
            print("Bitcode \(String(format: "%X", bitcode)) (mask 0x\(String(format: "%04X", bitcodeMask)))")
        }
        
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
    // Max observed value is 8
    guard (2...12).contains(origBitcodeWidth) else {
        throw CvPcError.invalidBitcodeWidth(width: origBitcodeWidth)
    }
    guard (1...256).contains(paletteSize) else {
        throw CvPcError.invalidPaletteSize(paletteSize: paletteSize)
    }

    if DEBUG >= 1 {
        print("Image width is 0x\(String(format: "%04X", imageWidth))")
        print("image height is 0x\(String(format: "%04X", imageHeight))")
        print("initial bitcode width \(origBitcodeWidth)")
        print("palette size \(paletteSize)\n")
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
        
        if DEBUG >= 4 {
            print("\(i): \(palette[i])")
        }
    }
    
    // Initialize decompression constants
    let resetDictBitcode = 1 << origBitcodeWidth
    let doneBitcode = (1 << origBitcodeWidth) + 1
    var prevBitcode = resetDictBitcode
    var nextBitcode = doneBitcode + 1
    var bitcodeWidth = origBitcodeWidth
    var bitcodeMask = ((2 << origBitcodeWidth) - 1)
    var foundDoneBitcode = false
    
    if DEBUG >= 1 {
        print("\nresetDictBitcode 0x\(String(format: "%02X", resetDictBitcode))")
        print("doneBitcode             0x\(String(format: "%02X", doneBitcode))")
        print("prevBitcode 0x\(String(format: "%02X", prevBitcode))")
        print("nextBitcode 0x\(String(format: "%02X", nextBitcode))")
    }
    
    var picture = [UInt8](repeating: 0, count: Int(imageWidth) * Int(imageHeight))
    var pictureCur = 0
    
    // Fill in dictionary
    var dictionary = [DictionaryEntry](repeating: DictionaryEntry(), count: 0x2000)
    
    // Fill table with initial bitcodes that correspond to the palette colors
    for bitcode in 0..<(1 << origBitcodeWidth) {
        dictionary[bitcode].colorIndex = UInt8(bitcode)
        dictionary[bitcode].prefixBitcode = -1
        dictionary[bitcode].length = 1
    }
    
    // Main loop
    while let bitcode = bitReader.getBitcode(bitcodeWidth: bitcodeWidth) {
        
        if DEBUG >= 3 {
            print("")
        }

        // Handle Done
        if bitcode == doneBitcode {
            if DEBUG >= 2 {
                print("Got doneBitcode(\(String(format: "%X", bitcode)))")
            }
            foundDoneBitcode = true
            break
        }
        
        // Handle reset
        if bitcode == resetDictBitcode {
            if DEBUG >= 2 {
                print("Got resetDictBitcode(\(String(format: "%X", bitcode)))")
            }
            prevBitcode = resetDictBitcode
            nextBitcode = doneBitcode + 1
            bitcodeWidth = origBitcodeWidth
            bitcodeMask = ((2 << origBitcodeWidth) - 1)
            continue
        }
        
        // First case: immediately after reset
        if prevBitcode == resetDictBitcode {
            if DEBUG >= 3 {
                print(" 1: Previous bitcode was resetDictBitcode")
                print(" *** length \(dictionary[bitcode].length)")
            }
            prevBitcode = bitcode
            picture[pictureCur] = dictionary[bitcode].colorIndex
            pictureCur += 1
            
            if DEBUG >= 4 {
                print("  1: Color \(String(format: "%02X", dictionary[bitcode].colorIndex))")
            }
            continue
        }
        
        dictionary[nextBitcode].length = dictionary[prevBitcode].length + 1
        dictionary[nextBitcode].prefixBitcode = prevBitcode
        
        var pixel: UInt8 = 0
        
        // Second case: bitcode is already in the dictionary
        if bitcode < nextBitcode {
            if DEBUG >= 3 {
                print(" 2: Bitcode is in dictionary")
                print(" *** length \(dictionary[bitcode].length)")
            }
            
            pictureCur += Int(dictionary[bitcode].length)
            var pixelIndex = pictureCur
            
            prevBitcode = bitcode
            var currentBitcode = bitcode
            
            // Fill in colors from bitcode dictionary word
            repeat {
                pixelIndex -= 1
                if DEBUG >= 4 {
                    print("  2: Color \(String(format: "%02X", dictionary[currentBitcode].colorIndex))")
                }
                picture[pixelIndex] = dictionary[currentBitcode].colorIndex
                pixel = dictionary[currentBitcode].colorIndex
                currentBitcode = dictionary[currentBitcode].prefixBitcode
            } while currentBitcode != -1
            
        // Third case: bitcode not in dictionary yet
        } else if bitcode == nextBitcode {
            if DEBUG >= 3 {
                print(" 3: Bitcode is not in dictionary")
                print(" *** length \(dictionary[prevBitcode].length) + 1 = \(dictionary[prevBitcode].length + 1)")
            }
            
            pictureCur += Int(dictionary[prevBitcode].length) + 1
            var pixelIndex = pictureCur - 1
            
            var currentBitcode = prevBitcode
            repeat {
                pixelIndex -= 1
                picture[pixelIndex] = dictionary[currentBitcode].colorIndex
                pixel = dictionary[currentBitcode].colorIndex
                
                if DEBUG >= 4 {
                    print("  3: Color \(String(format: "%02X", dictionary[currentBitcode].colorIndex))")
                }
                currentBitcode = dictionary[currentBitcode].prefixBitcode
            } while currentBitcode != -1
            
            picture[pictureCur - 1] = pixel
            
            if DEBUG >= 4 {
                print("  3: LAST Color \(String(format: "%02X", pixel))")
            }
            
            prevBitcode = bitcode
        } else {
            throw CvPcError.invalidBitcodeSequence(bitcode: bitcode, nextBitcode: nextBitcode)
        }
        
        // Assign to nextBitcode previous_sequence + current_sequence[0]
        dictionary[nextBitcode].colorIndex = UInt8(pixel)
        
        if DEBUG >= 3 {
            print("Inserting to \(nextBitcode) sequence(rev):", terminator: "")
            var index = nextBitcode
            repeat {
                print(" 0x\(String(format: "%02X", dictionary[index].colorIndex))", terminator: "")
                index = dictionary[index].prefixBitcode
            } while index != -1
            print("")
        }
        
        nextBitcode += 1
        if nextBitcode > bitcodeMask {
            if bitcodeWidth < BITCODE_WIDTH_MAX {
                bitcodeWidth += 1
                bitcodeMask = (bitcodeMask << 1) | 0x1
                if DEBUG >= 3 {
                    print("Resizing bitcodeWidth to \(bitcodeWidth)")
                }
            } else if DEBUG >= 3 {
                print(
                    "**** Can't resize bitcode width to 12, " + 
                    "nextBitcode 0x\(String(format: "%04X", nextBitcode)), " +
                    "bitcodeMask 0x\(String(format: "%04X", bitcodeMask))"
                )
            }
        }
    }

    guard foundDoneBitcode else {
        throw CvPcError.doneBitcodeNotFound
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

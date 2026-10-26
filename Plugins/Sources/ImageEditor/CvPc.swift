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


// Format is:
// 0x00 - width
// 0x02 - height
// 0x04 - initial bitcode width
// 0x05 - palette size - 1
// 0x06 - palette data (3 byte r/g/b tuple)
// 0xnn - LZW-and-RLE compressed image data
struct CvPc {
    var imageRep: NSBitmapImageRep
    
    init?(_ reader: BinaryDataReader) throws {
        let compressed = try reader.readData(length: reader.bytesRemaining)
        let imgData = decodeImage(data: compressed)
        guard imgData != nil else {
            print("Couldn't create PaletteImage")
            return nil
        }
        imageRep = createImageRepFromPaletteImage(from: imgData!)!
    }

    static func rep(_ data: Data) -> NSBitmapImageRep? {
        let reader = BinaryDataReader(data, bigEndian: true)
        return try? Self(reader)?.imageRep
    }
}


func createImageRepFromPaletteImage(from paletteImage: PaletteImage) -> NSBitmapImageRep? {
    let width = Int(paletteImage.width)
    let height = Int(paletteImage.height)
    
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
        return nil
    }
    
    // Get pointer to the bitmap data
    guard let bitmapData = bitmapRep.bitmapData else {
        return nil
    }
    
    // Fill in the pixel data from the palette
    for y in 0..<height {
        for x in 0..<width {
            let pixelIndex = y * width + x
            let colorIndex = Int(paletteImage.data[pixelIndex])
            let color = paletteImage.palette[colorIndex]
            
            let offset = (y * width + x) * 3
            bitmapData[offset] = color.red
            bitmapData[offset + 1] = color.green
            bitmapData[offset + 2] = color.blue
        }
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
    
    private func readByte() -> UInt8? {
        guard position < data.endIndex else {
            return nil
        }
        let byte = data[position]
        position += 1
        return byte
    }
    
    func readNumber(bytes: Int) -> UInt32 {
        var number: UInt32 = 0
        for i in 0..<bytes {
            guard let byte = readByte() else { break }
            number += UInt32(byte) << ((bytes - 1 - i) * 8)
        }
        return number
    }
    
    func getBitcode(bitcodeWidth: Int) -> Int? {
        while numberOfReadBits < bitcodeWidth + 1 {
            if dataChunkLength == 0 {
                guard let chunkSize = readByte() else { return nil }
                dataChunkLength = Int(chunkSize)
                
                if DEBUG >= 1 {
                    print("!! new chunk of data, size 0x\(String(format: "%02X", dataChunkLength))")
                }
                
                if dataChunkLength == 0 {
                    if DEBUG >= 1 {
                        print("******Double data_chunk zero")
                    }
                    return 0
                }
            } else {
                guard let byte = readByte() else { return nil }
                readBits = (UInt32(byte) << numberOfReadBits) | readBits
                numberOfReadBits += 8
                
                if DEBUG >= 2 {
                    print("!! (0x\(String(format: "%02X", dataChunkLength)))read compressed byte 0x\(String(format: "%02X", byte))")
                }
                dataChunkLength -= 1
            }
        }
        
        // Get bitcode from read_bits buffer
        let bitcodeMask = ((2 << bitcodeWidth) - 1)
        let bitcode = Int(readBits & UInt32(bitcodeMask))
        
        if DEBUG >= 2 {
            print("Bitcode \(String(format: "%X", bitcode)) (mask 0x\(String(format: "%04X", bitcodeMask)))")
        }
        
        // Empty bits we have used in bitcode from read_bits buffer
        readBits >>= (bitcodeWidth + 1)
        numberOfReadBits -= (bitcodeWidth + 1)
        
        return bitcode
    }
}

// Decodes a compressed image into a PaletteImage
func decodeImage<T: Collection>(data: T) -> PaletteImage? where T.Element == UInt8 {
    let byteArray = ArraySlice(data)
    let bitReader = BitReader(data: byteArray)
    
    // Image header
    let imageWidth = Int(bitReader.readNumber(bytes: 2))
    let imageHeight = Int(bitReader.readNumber(bytes: 2))
    let origBitcodeWidth = Int(bitReader.readNumber(bytes: 1))
    let paletteSize = Int(bitReader.readNumber(bytes: 1)) + 1

    if DEBUG >= 1 {
        print("Image width is 0x\(String(format: "%04X", imageWidth))")
        print("image height is 0x\(String(format: "%04X", imageHeight))")
        print("initial bitcode width \(origBitcodeWidth)")
        print("palette_size \(paletteSize)\n")
    }
    
    // Read palette
    if DEBUG >= 4 {
        print("\nPalette (0x\(String(format: "%02X", paletteSize))):")
    }
    
    var palette = [Color]()
    for i in 0..<paletteSize {
        let red = UInt8(bitReader.readNumber(bytes: 1))
        let green = UInt8(bitReader.readNumber(bytes: 1))
        let blue = UInt8(bitReader.readNumber(bytes: 1))
        palette.append(Color(red: red, green: green, blue: blue))
        
        if DEBUG >= 4 {
            print(" \(String(format: "%03d", i)) - r \(String(format: "%03d", red)) g \(String(format: "%03d", green)) b \(String(format: "%03d", blue))")
        }
    }
    
    // Initialize decompression constants
    let RESET_DICTIONARY_BITCODE = 1 << origBitcodeWidth
    let DONE_BITCODE = (1 << origBitcodeWidth) + 1
    var prevBitcode = RESET_DICTIONARY_BITCODE
    var nextBitcode = DONE_BITCODE + 1
    var bitcodeWidth = origBitcodeWidth
    var bitcodeMask = ((2 << origBitcodeWidth) - 1)
    
    if DEBUG >= 1 {
        print("\nRESET_DICTIONARY_BITCODE 0x\(String(format: "%02X", RESET_DICTIONARY_BITCODE))")
        print("DONE_BITCODE             0x\(String(format: "%02X", DONE_BITCODE))")
        print("prev_bitcode 0x\(String(format: "%02X", prevBitcode))")
        print("next_bitcode 0x\(String(format: "%02X", nextBitcode))")
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
    while let bitcode = bitReader.getBitcode(bitcodeWidth: bitcodeWidth),
          bitcode != DONE_BITCODE {
        
        if DEBUG >= 3 {
            print("")
        }
        
        // Handle reset
        if bitcode == RESET_DICTIONARY_BITCODE {
            if DEBUG >= 2 {
                print("Got RESET_DICTIONARY_BITCODE(\(String(format: "%X", bitcode)))")
            }
            prevBitcode = RESET_DICTIONARY_BITCODE
            nextBitcode = DONE_BITCODE + 1
            bitcodeWidth = origBitcodeWidth
            bitcodeMask = ((2 << origBitcodeWidth) - 1)
            continue
        }
        
        // First case: immediately after reset
        if prevBitcode == RESET_DICTIONARY_BITCODE {
            if DEBUG >= 3 {
                print(" 1: Previous bitcode was RESET_DICTIONARY_BITCODE")
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
            print("Error: Third case, bitcode 0x\(String(format: "%04X", bitcode)) is not equal to next_bitcode 0x\(String(format: "%04X", nextBitcode))")
            break
        }
        
        // Assign to next_bitcode previous_sequence + current_sequence[0]
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
        if nextBitcode > bitcodeMask && bitcodeWidth < BITCODE_WIDTH_MAX {
            bitcodeWidth += 1
            bitcodeMask = (bitcodeMask << 1) | 0x1
            if DEBUG >= 3 {
                print("Resizing bitcode_width to \(bitcodeWidth)")
            }
        } else if nextBitcode > bitcodeMask && DEBUG >= 3 {
            print("**** Can't resize bitcode width to 12, next_bitcode 0x\(String(format: "%04X", nextBitcode)), bitcode_mask 0x\(String(format: "%04X", bitcodeMask))")
        }
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

/**
 * This module provides a codec for the Portable Network Graphics format.
 *
 * See_Also:
 *     https://www.libpng.org/pub/png/,
 *     https://www.w3.org/TR/png/,
 *     https://www.zlib.net/
 *
 * Copyright: Copyright (C) 2026 Valentino Giudice
 * License: BSL-1.0
 * Authors: Valentino Giudice, https://www.functorfault.net/
 */
module imaging.files.png;

import imaging : Bitmap, bpp, Color, indexed, pixelDataAlloc, PixelFormat, Rectangle;
import imaging.files : beConv, ImageFormat, ImageInfo, ImageLoader, LoadState, SingleImageFormat;
import std.math.algebraic : abs;
import std.algorithm.comparison : among;
import std.algorithm.searching : maxElement;
import std.algorithm.iteration : map, sum;
import std.algorithm.searching : all, any, canFind, count, find;
import std.array : array;
import std.ascii : isAlpha;
import std.conv : to;
import std.exception : assumeUnique, enforce;
import std.range : iota;
import std.stdio : File, SEEK_CUR, SEEK_SET;
import std.traits : EnumMembers, isArray;
import std.typecons : Nullable, nullable;
import std.zlib : compress, crc32, uncompress, ZlibException;

/// Magic signature of the Portable Network Graphics format.
public immutable ubyte[8] pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];

private alias ChunkType = char[4];

private bool ancillary(ChunkType type)
{
    return (type[0] >> 5) & 1;
}

private struct ChunkHeader
{
    uint length;
    ChunkType type;
}

package(imaging.files) enum ColorType : ubyte
{
    Grayscale = 0,
    RgbTriple = 2,
    Indexed = 3,
    GrayscaleAlpha = 4,
    Rgba = 6
}

private immutable ubyte[8][8] adamPattern = [
    [1, 6, 4, 6, 2, 6, 4, 6], [7, 7, 7, 7, 7, 7, 7, 7], [5, 6, 5, 6, 5, 6, 5,
        6], [7, 7, 7, 7, 7, 7, 7, 7], [3, 6, 4, 6, 3, 6, 4, 6],
    [7, 7, 7, 7, 7, 7, 7, 7], [5, 6, 5, 6, 5, 6, 5, 6], [7, 7, 7, 7, 7, 7, 7, 7]
];

private size_t adamLineSize(size_t rowSize)
{
    return rowSize > 0 ? rowSize + 1 : 0;
}

private ubyte paethPredictor(ubyte a, ubyte b, ubyte c)
{
    int p = a + b - c;
    uint pa = abs(p - a);
    uint pb = abs(p - b);
    uint pc = abs(p - c);
    if (pa <= pb && pa <= pc)
    {
        return a;
    }
    if (pb <= pc)
    {
        return b;
    }
    return c;
}

package(imaging.files) struct Data_IHDR
{
align(1):
    uint width;
    uint height;
    ubyte bitDepth;
    ubyte colorType;
    ubyte compressionMethod;
    ubyte filterMethod;
    ubyte interlaceMethod;

    @property bool valid()
    {
        if (!(0 < this.width && this.width < 1 << 31))
        {
            return false;
        }
        if (!(0 < this.height && this.height < 1 << 31))
        {
            return false;
        }
        if (!among!(EnumMembers!ColorType)(this.colorType))
        {
            return false;
        }
        final switch (this.colorType)
        {
        case ColorType.Grayscale:
            if (!among!(1, 2, 4, 8, 16)(this.bitDepth))
            {
                return false;
            }
            break;
        case ColorType.RgbTriple, ColorType.GrayscaleAlpha, ColorType.Rgba:
            if (!among!(8, 16)(this.bitDepth))
            {
                return false;
            }
            break;
        case ColorType.Indexed:
            if (!among!(1, 2, 4, 8)(this.bitDepth))
            {
                return false;
            }
            break;
        }
        if (this.compressionMethod != 0)
        {
            return false;
        }
        if (this.filterMethod != 0)
        {
            return false;
        }
        if (this.interlaceMethod != 0 && this.interlaceMethod != 1)
        {
            return false;
        }
        return true;
    }
}

package(imaging.files) struct Data_acTL
{
    uint numFrames;
    uint numPlays;
}

package(imaging.files) struct Data_fcTL
{
align(1):
    uint sequenceNumber;
    uint width;
    uint height;
    uint xOffset;
    uint yOffset;
    ushort delayNum;
    ushort delayDen;
    ubyte disposeOp;
    ubyte blendOp;
}

package(imaging.files) enum DisposeOp : ubyte
{
    APNG_DISPOSE_OP_NONE,
    APNG_DISPOSE_OP_BACKGROUND,
    APNG_DISPOSE_OP_PREVIOUS
}

package(imaging.files) enum BlendOp : ubyte
{
    APNG_BLEND_OP_SOURCE,
    APNG_BLEND_OP_OVER
}

private enum FilterType : ubyte
{
    None,
    Sub,
    Up,
    Average,
    Paeth
}

private ubyte fillByte(ubyte bitValues, int bitCount)
{
    while (bitCount < 8)
    {
        bitValues |= bitValues << bitCount;
        bitCount *= 2;
    }
    return bitValues;
}

private size_t bitShift(int bpp, size_t x)
{
    return 8 - (1 + (x % (8 / bpp))) * bpp;
}

private size_t maxCompressedSize(size_t originalSize)
{
    return 11 + (1135 * originalSize + 999) / 1000;
}

/**
 * Checks if the given Portable Network Graphics file is animated.
 * If it is, the proper format for the file is [ApngFormat].
 * If it isn't, the proper format for the file is [PngFormat].
 * This function never fails due to invalid data.
 *
 * Params:
 *     fp =
 *         The file pointer to be used.
 *         It must be open for binary read.
 *         Any data preceding the file pointer is ignored.
 *     afterSignature =
 *         Whether the signature has already been read.
 *         `false` if the file pointer points right before the magic signature.
 *         `true` if the file pointer points right after the magic signature.
 *     maxChunks =
 *         The maximum amount of chunks to be read from the file.
 *         If the file has more chunks, it will be deemed to be invalid.
 *
 * Returns:
 *     `true` has been found to be animated.
 *     `false` otherwise.
 */
public bool checkAnimated(File fp, bool afterSignature, int maxChunks = 1024)
{
    ulong s = fp.tell;
    if (!afterSignature)
    {
        ubyte[8] signature;
        if (fp.rawRead(signature[]) != pngSignature)
        {
            fp.seek(s, SEEK_SET);
            return false;
        }
    }
    for (int i = 0; i < maxChunks; i++)
    {
        ChunkHeader ch;
        if (fp.rawRead((&ch)[0 .. 1]).length != 1)
        {
            fp.seek(s, SEEK_SET);
            return false;
        }
        ch = beConv(ch);
        if (ch.type == "acTL")
        {
            fp.seek(s, SEEK_SET);
            return true;
        }
        if (ch.type == "IDAT")
        {
            fp.seek(s, SEEK_SET);
            return false;
        }
        ulong p = fp.tell;
        fp.seek(ch.length + 4, SEEK_CUR);
        if (fp.tell - p != ch.length + 4)
        {
            fp.seek(s, SEEK_SET);
            return false;
        }
    }
    fp.seek(s, SEEK_SET);
    return false;
}

package(imaging.files) struct BasePngLoader(bool Animated)
{
    private File _fp;
    private ImageFormat _format;
    private int _maxChunks;
    private LoadState _state;
    private ImageInfo _info;
    private int _chunkIndex;
    private ubyte[] _buffer;
    private bool[ChunkType] _seen;
    private ColorType _colorType;
    private int _valuesPerPixel;
    private bool _interlaced;
    private ubyte _bitDepth;
    private int _paletteLength;
    private Color[] _palette;
    private ushort[3] _transparentColor;
    private size_t _uncompressedSize;
    private ubyte[] _imgData;
    private bool _afterIDAT;
    private bool _fileEnd;
    private ubyte[] _rawData;
    static if (Animated)
    {
        private bool _animated;
        private uint _sequenceNumber;
        private uint _numFrames;
        private uint _numPlays;
        private uint _frameIndex;
        private PixelFormat _originalPixelFormat;
        private Rectangle _frameRectangle;
        private double _frameDuration;
        private DisposeOp _disposeOp;
        private BlendOp _blendOp;
        private bool _frameEnd;
        private Bitmap _canvas;
        private PixelFormat _prevPixelFormat;
    }

    private bool parseInitialInfo()
    {
        this._state = LoadState.Invalid;
        ubyte[8] signature;
        if (this._fp.rawRead(signature[]) != pngSignature)
        {
            return false;
        }
        this._chunkIndex = 0;
        this._buffer = [];
        this._fileEnd = false;
        this._palette = null;
        for (;;)
        {
            ChunkHeader ch;
            if (this._fp.rawRead((&ch)[0 .. 1]).length != 1)
            {
                return false;
            }
            ch = beConv(ch);
            if (ch.type == "IDAT")
            {
                static if (Animated)
                {
                    if (!this._animated && this._seen.get("fcTL", false))
                    {
                        return false;
                    }
                }
                this._fp.seek(-to!int(ChunkHeader.sizeof), SEEK_CUR);
                return true;
            }
            else if (!this.processChunk(ch))
            {
                return false;
            }
        }
    }

    package(imaging.files) this(File fp, ImageFormat format, int maxChunks = 1024)
    {
        this._fp = fp;
        this._format = format;
        this._maxChunks = maxChunks;
        static if (Animated)
        {
            this._animated = false;
            this._sequenceNumber = 0;
            this._frameIndex = 0;
            if (this.parseInitialInfo())
            {
                this._state = LoadState.BeforeInfo;
            }
        }
        else
        {
            this._state = LoadState.BeforeInfo;
        }
    }

    package(imaging.files) LoadState state() const
    {
        return this._state;
    }

    package(imaging.files) int length() const
    {
        static if (Animated)
        {
            return this._animated ? this._numFrames : 1;
        }
        else
        {
            return 1;
        }
    }

    static if (Animated)
    {
        @property package(imaging.files) int width() const
        {
            return this._info.width;
        }

        @property package(imaging.files) int height() const
        {
            return this._info.height;
        }

        @property package(imaging.files) double duration() const
        {
            if (this._animated)
            {
                return this._frameDuration;
            }
            return 0;
        }
    }

    package(imaging.files) Nullable!ImageInfo nextInfo()
    in (this.state == LoadState.BeforeInfo || this.state == LoadState.BeforeImage)
    {
        static if (Animated)
        {
            this._state = LoadState.Invalid;
            if (this._animated && (this._frameIndex != 0 || !this._seen.get("fcTL", false)))
            {
                bool loop;
                do
                {
                    ChunkHeader ch;
                    if (this._fp.rawRead((&ch)[0 .. 1]).length != 1)
                    {
                        return Nullable!ImageInfo();
                    }
                    ch = beConv(ch);
                    loop = ch.type != "fcTL";
                    if (!this.processChunk(ch))
                    {
                        return Nullable!ImageInfo();
                    }
                }
                while (loop);
            }
        }
        else
        {
            if (!this.parseInitialInfo())
            {
                return Nullable!ImageInfo();
            }
        }
        this._state = LoadState.BeforeImage;
        return nullable(this._info);
    }

    private bool skipChunk(ChunkType type, uint length)
    {
        if (length < 1 << 16)
        {
            return this.readData(type, length);
        }
        ulong p = this._fp.tell;
        this._fp.seek(length + 4, SEEK_CUR);
        return this._fp.tell - p == length;
    }

    private bool readData(ChunkType type, uint length)
    {
        this._buffer.length = length;
        if (this._fp.rawRead(this._buffer).length != length)
        {
            return false;
        }
        uint crc;
        if (this._fp.rawRead((&crc)[0 .. 1]).length != 1)
        {
            return false;
        }
        crc = beConv(crc);
        return crc == crc32(crc32(0, type), this._buffer);
    }

    private bool processChunk(ChunkHeader ch)
    {
        if (this._chunkIndex >= this._maxChunks)
        {
            return false;
        }
        ChunkType[] allowedOnce = [
            "IHDR", "PLTE", "IEND", "cHRM", "gAMA", "iCCP", "sBIT", "sRGB",
            "bKGD", "hIST", "tRNS", "pHYs", "tIME", "acTL"
        ];
        ChunkType[] groupB = ["cHRM", "gAMA", "iCCP", "sBIT", "sRGB"];
        ChunkType[] groupC = ["bKGD", "hIST", "tRNS"];
        ChunkType[] groupD = ["pHYs", "sPLT", "acTL"];
        if (ch.length >= 1 << 31)
        {
            return false;
        }
        if (!all!(c => isAlpha(c))(ch.type[]))
        {
            return false;
        }
        if (!this._seen.get("IHDR", false) && ch.type != "IHDR")
        {
            return false;
        }
        if (canFind(allowedOnce, ch.type) && this._seen.get(ch.type, false))
        {
            return false;
        }
        this._seen[ch.type] = true;
        if (canFind(groupB, ch.type) && (this._seen.get("PLTE", false)
                || this._seen.get("IDAT", false)))
        {
            return false;
        }
        if ((canFind(groupC, ch.type) || canFind(groupD, ch.type)) && this._seen.get("IDAT", false))
        {
            return false;
        }
        if (ch.type == "IDAT")
        {
            if (this._afterIDAT)
            {
                return false;
            }
        }
        else if (this._seen.get("IDAT", false))
        {
            this._afterIDAT = true;
        }
        static if (Animated)
        {
            if (this._seen.get("fcTL", false) && ch.type != "fdAT" && ch.type != "IDAT")
            {
                assert(this._frameIndex <= this._numFrames);
                if ((ch.type == "fcTL" && this._numFrames != 0) ^ (
                        this._frameIndex != this._numFrames))
                {
                    return false;
                }
                this._frameEnd = true;
            }
        }
        switch (ch.type)
        {
        case "IHDR":
            if (ch.length != Data_IHDR.sizeof)
            {
                return false;
            }
            if (!this.readData(ch.type, ch.length))
            {
                return false;
            }
            Data_IHDR d_IHDR = (cast(Data_IHDR[]) this._buffer)[0];
            d_IHDR = beConv(d_IHDR);
            if (!d_IHDR.valid)
            {
                return false;
            }
            PixelFormat pixelFormat;
            final switch (d_IHDR.colorType)
            {
            case ColorType.Grayscale:
                pixelFormat = PixelFormat.Format8bppGray;
                break;
            case ColorType.RgbTriple:
                pixelFormat = PixelFormat.Format24bppRgbBE;
                break;
            case ColorType.Indexed:
                if (d_IHDR.bitDepth == 1)
                {
                    pixelFormat = PixelFormat.Format1bppIndexed;
                }
                else if (d_IHDR.bitDepth == 2 || d_IHDR.bitDepth == 4)
                {
                    pixelFormat = PixelFormat.Format4bppIndexed;
                }
                else
                {
                    pixelFormat = PixelFormat.Format8bppIndexed;
                }
                break;
            case ColorType.GrayscaleAlpha, ColorType.Rgba:
                pixelFormat = PixelFormat.Format32bppRgbaBE;
                break;
            }
            static if (Animated)
            {
                this._originalPixelFormat = pixelFormat;
            }
            this._colorType = cast(ColorType) d_IHDR.colorType;
            final switch (this._colorType)
            {
            case ColorType.Grayscale:
                this._valuesPerPixel = 1;
                break;
            case ColorType.RgbTriple:
                this._valuesPerPixel = 3;
                break;
            case ColorType.Indexed:
                this._valuesPerPixel = 1;
                break;
            case ColorType.GrayscaleAlpha:
                this._valuesPerPixel = 2;
                break;
            case ColorType.Rgba:
                this._valuesPerPixel = 4;
                break;
            }
            this._interlaced = !!d_IHDR.interlaceMethod;
            this._bitDepth = d_IHDR.bitDepth;
            this._info = ImageInfo(this._format, d_IHDR.width, d_IHDR.height, pixelFormat);
            return true;
        case "PLTE":
            if (this._colorType == ColorType.Grayscale || this._colorType
                    == ColorType.GrayscaleAlpha)
            {
                return false;
            }
            if (any!(t => this._seen.get(t, false))(groupC))
            {
                return false;
            }
            if (ch.length == 0 || ch.length % 3 != 0)
            {
                return false;
            }
            this._paletteLength = ch.length / 3;
            if (this._colorType == ColorType.Indexed)
            {
                if (ch.length > (1 << this._bitDepth) * 3)
                {
                    return false;
                }
                this._palette = new Color[this._paletteLength];
                if (!this.readData(ch.type, ch.length))
                {
                    return false;
                }
                for (int i = 0; i < this._paletteLength; i++)
                {
                    this._palette[i] = Color(this._buffer[i * 3],
                            this._buffer[i * 3 + 1], this._buffer[i * 3 + 2]);
                }
                return true;
            }
            if (ch.length > 255 * 3)
            {
                return false;
            }
            return this.skipChunk(ch.type, ch.length);
        case "hIST":
            if (!this._seen.get("PLTE", false))
            {
                return false;
            }
            if (ch.length != this._paletteLength * 2)
            {
                return false;
            }
            return this.skipChunk(ch.type, ch.length);
        case "tRNS":
            if (this._colorType == ColorType.GrayscaleAlpha || this._colorType == ColorType.Rgba)
            {
                return false;
            }
            if (this._colorType == ColorType.Indexed)
            {
                if (ch.length > this._palette.length)
                {
                    return false;
                }
                if (!this.readData(ch.type, ch.length))
                {
                    return false;
                }
                for (int i = 0; i < ch.length; i++)
                {
                    this._palette[i].a = this._buffer[i];
                }
                return true;
            }
            this._info.pixelFormat = PixelFormat.Format32bppRgbaBE;
            static if (Animated)
            {
                this._originalPixelFormat = this._info.pixelFormat;
            }
            if (this._colorType == ColorType.Grayscale)
            {
                if (ch.length != 2)
                {
                    return false;
                }
                if (!this.readData(ch.type, ch.length))
                {
                    return false;
                }
                this._transparentColor[] = this._buffer[0] << 8 | this._buffer[1];
            }
            if (this._colorType == ColorType.RgbTriple)
            {
                if (ch.length != 6)
                {
                    return false;
                }
                if (!this.readData(ch.type, ch.length))
                {
                    return false;
                }
                this._transparentColor[0] = this._buffer[0] << 8 | this._buffer[1];
                this._transparentColor[1] = this._buffer[2] << 8 | this._buffer[3];
                this._transparentColor[2] = this._buffer[4] << 8 | this._buffer[5];
            }
            return true;
        case "IDAT":
            static if (Animated)
            {
                if (this._animated && !this._seen.get("fcTL", false))
                {
                    return this.skipChunk(ch.type, ch.length);
                }
            }
            if (ch.length > maxCompressedSize(this._uncompressedSize) - this._imgData.length)
            {
                return false;
            }
            if (!this.readData(ch.type, ch.length))
            {
                return false;
            }
            this._imgData ~= this._buffer;
            return true;
            static if (Animated)
            {
        case "acTL":
                if (ch.length != Data_acTL.sizeof)
                {
                    return false;
                }
                if (!this.readData(ch.type, ch.length))
                {
                    return false;
                }
                Data_acTL d_acTL = (cast(Data_acTL[]) this._buffer)[0];
                d_acTL = beConv(d_acTL);
                if (!(0 < d_acTL.numFrames && d_acTL.numFrames <= int.max))
                {
                    return false;
                }
                this._animated = true;
                this._numFrames = d_acTL.numFrames;
                this._numPlays = d_acTL.numPlays;
                this._canvas = new Bitmap(this._info.width, this._info.height,
                        PixelFormat.Format32bppRgba);
                (cast(int[]) this._canvas.data)[] = 0;
                return true;
        case "fcTL":
                if (ch.length != Data_fcTL.sizeof)
                {
                    return false;
                }
                if (!this.readData(ch.type, ch.length))
                {
                    return false;
                }
                Data_fcTL d_fcTL = (cast(Data_fcTL[]) this._buffer)[0];
                d_fcTL = beConv(d_fcTL);
                if (d_fcTL.sequenceNumber != this._sequenceNumber)
                {
                    return false;
                }
                if (d_fcTL.width == 0 || d_fcTL.height == 0)
                {
                    return false;
                }
                if (this._seen.get("IDAT", false))
                {
                    if (!this._animated)
                    {
                        return false;
                    }
                    if ((cast(ulong) d_fcTL.width) + d_fcTL.xOffset > this._info.width)
                    {
                        return false;
                    }
                    if ((cast(ulong) d_fcTL.height) + d_fcTL.yOffset > this._info.height)
                    {
                        return false;
                    }
                }
                else
                {
                    assert(this._frameIndex == 0);
                    if (d_fcTL.width != this._info.width || d_fcTL.height != this._info.height)
                    {
                        return false;
                    }
                    if (d_fcTL.xOffset != 0 || d_fcTL.yOffset != 0)
                    {
                        return false;
                    }
                }
                this._frameRectangle = Rectangle(d_fcTL.xOffset, d_fcTL.yOffset,
                        d_fcTL.width, d_fcTL.height);
                double den = d_fcTL.delayDen == 0 ? 100 : d_fcTL.delayDen;
                this._frameDuration = d_fcTL.delayNum / den;
                if (!among!(EnumMembers!DisposeOp)(d_fcTL.disposeOp))
                {
                    return false;
                }
                if (!among!(EnumMembers!BlendOp)(d_fcTL.blendOp))
                {
                    return false;
                }
                this._disposeOp = cast(DisposeOp) d_fcTL.disposeOp;
                if (this._frameIndex == 0)
                {
                    if (this._disposeOp == DisposeOp.APNG_DISPOSE_OP_PREVIOUS)
                    {
                        this._disposeOp = DisposeOp.APNG_DISPOSE_OP_BACKGROUND;
                    }
                    this._blendOp = BlendOp.APNG_BLEND_OP_SOURCE;
                }
                else
                {
                    this._blendOp = cast(BlendOp) d_fcTL.blendOp;
                }
                if (this._disposeOp == DisposeOp.APNG_DISPOSE_OP_PREVIOUS)
                {
                    this._prevPixelFormat = this._info.pixelFormat;
                }
                if (this._blendOp == BlendOp.APNG_BLEND_OP_SOURCE)
                {
                    if (this._frameRectangle == Rectangle(0, 0,
                            this._info.width, this._info.height))
                    {
                        this._info.pixelFormat = this._originalPixelFormat;
                    }
                }
                else if (!(this._originalPixelFormat == PixelFormat.Format24bppRgbLE
                        || (this._originalPixelFormat.indexed
                        && all!(c => (c.a == 0 || c.a == 255))(this._palette))))
                {
                    if (this._canvas.opaque())
                    {
                        this._info.pixelFormat = PixelFormat.Format24bppRgbBE;
                    }
                    else
                    {
                        this._info.pixelFormat = PixelFormat.Format32bppRgbaBE;
                    }
                }
                this._sequenceNumber++;
                return true;
        case "fdAT":
                if (!this._seen.get("fcTL", false))
                {
                    return false;
                }
                size_t maxLength = 4 + maxCompressedSize(
                        this._uncompressedSize) - this._imgData.length;
                if (!(4 <= ch.length && ch.length < maxLength))
                {
                    return false;
                }
                if (!this.readData(ch.type, ch.length))
                {
                    return false;
                }
                uint sequenceNumber = (cast(uint[1]) this._buffer[0 .. 4])[0];
                sequenceNumber = beConv(sequenceNumber);
                if (sequenceNumber != this._sequenceNumber)
                {
                    return false;
                }
                this._imgData ~= this._buffer[4 .. $];
                this._sequenceNumber++;
                return true;
            }
        case "IEND":
            if (ch.length != 0)
            {
                return false;
            }
            this._fileEnd = true;
            return this.skipChunk("IEND", 0);
        default:
            if (ch.type.ancillary)
            {
                return this.skipChunk(ch.type, ch.length);
            }
            return false;
        }
        this._chunkIndex++;
    }

    private bool unfilter(ubyte[] rawData, size_t rowSize, size_t rowCount)
    {
        assert(rawData.length == adamLineSize(rowSize) * rowCount);
        if (rowSize == 0 || rowCount == 0)
        {
            return true;
        }
        int bytesPerPixel = (this._bitDepth * this._valuesPerPixel + 7) / 8;
        size_t index = 0;
        for (size_t y = 0; y < rowCount; y++)
        {
            if (!among!(EnumMembers!FilterType)(rawData[index]))
            {
                return false;
            }
            FilterType filterType = cast(FilterType) rawData[index];
            rawData[index++] = FilterType.None;
            final switch (filterType)
            {
            case FilterType.None:
                index += rowSize;
                break;
            case FilterType.Sub:
                index += bytesPerPixel;
                for (size_t x = bytesPerPixel; x < rowSize; x++)
                {
                    rawData[index] += rawData[index - bytesPerPixel];
                    index++;
                }
                break;
            case FilterType.Up:
                if (y > 0)
                {
                    rawData[index .. index + rowSize] += rawData[index - rowSize - 1 .. index - 1];
                }
                index += rowSize;
                break;
            case FilterType.Average:
                for (size_t x = 0; x < rowSize; x++)
                {
                    ubyte left = x >= bytesPerPixel ? rawData[index - bytesPerPixel] : 0;
                    ubyte prior = y > 0 ? rawData[index - rowSize - 1] : 0;
                    rawData[index] += (left + prior) / 2;
                    index++;
                }
                break;
            case FilterType.Paeth:
                for (size_t x = 0; x < rowSize; x++)
                {
                    ubyte a = x >= bytesPerPixel ? rawData[index - bytesPerPixel] : 0;
                    ubyte b = y > 0 ? rawData[index - rowSize - 1] : 0;
                    ubyte c = (x >= bytesPerPixel && y > 0) ? rawData[index
                        - bytesPerPixel - rowSize - 1] : 0;
                    rawData[index] += paethPredictor(a, b, c);
                    index++;
                }
                break;
            }
        }
        assert(index == rawData.length);
        return true;
    }

    private bool readRawData()
    {
        static if (Animated)
        {
            if (this._animated)
            {
                this._frameEnd = false;
            }
        }
        bool loop = true;
        do
        {
            ChunkHeader ch;
            if (this._fp.rawRead((&ch)[0 .. 1]).length != 1)
            {
                return false;
            }
            ch = beConv(ch);
            bool animated;
            static if (Animated)
            {
                animated = this._animated;
            }
            else
            {
                animated = false;
            }
            if (animated)
            {
                if (ch.type == "fdAT" || ch.type == "IDAT")
                {
                    if (!this.processChunk(ch))
                    {
                        return false;
                    }
                }
                else
                {
                    this._fp.seek(-to!int(ChunkHeader.sizeof), SEEK_CUR);
                    loop = false;
                }
            }
            else
            {
                if (!this.processChunk(ch))
                {
                    return false;
                }
                loop = !this._fileEnd;
            }
        }
        while (loop);
        try
        {
            // TODO: Watch against zip bombs.
            this._rawData = cast(ubyte[]) uncompress(this._imgData, 0, 15);
            this._imgData = null;
            if (this._rawData.length != this._uncompressedSize)
            {
                return false;
            }
        }
        catch (ZlibException)
        {
            return false;
        }
        if (this._rawData.length != this._uncompressedSize)
        {
            return false;
        }
        return true;
    }

    package(imaging.files) Bitmap nextImage()
    in (this.state == LoadState.BeforeImage || this.state == LoadState.BeforeInfo)
    {
        if (this.state == LoadState.BeforeInfo)
        {
            this.nextInfo();
            if (this.state == LoadState.Invalid)
            {
                return null;
            }
        }
        assert(this.state == LoadState.BeforeImage);
        static if (Animated)
        {
            int width = this._animated ? this._frameRectangle.width : this._info.width;
            int height = this._animated ? this._frameRectangle.height : this._info.height;
            PixelFormat pixelFormat = this._originalPixelFormat;
        }
        else
        {
            int width = this._info.width;
            int height = this._info.height;
            PixelFormat pixelFormat = this._info.pixelFormat;
        }
        this._state = LoadState.Invalid;
        this._imgData = [];
        int bitsPerPixel = this._bitDepth * this._valuesPerPixel;
        size_t rowSize = (bitsPerPixel * width + 7) / 8;
        ubyte[] unfilteredData;
        if (this._interlaced)
        {
            size_t[7] rowLengths;
            size_t[7] rowSizes;
            size_t[7] rowCounts;
            ubyte[8][8] pattern;
            for (int i = 0; i < 8; i++)
            {
                pattern[i] = adamPattern[i][] - 1;
            }
            for (int i = 0; i < 7; i++)
            {
                ubyte[8] firstMatch = find!(r => canFind(r[], i))(pattern[])[0];
                rowLengths[i] = count!(v => v == i)(firstMatch[]);
                rowLengths[i] *= width / 8;
                rowLengths[i] += count!(v => v == i)(firstMatch[0 .. width % 8]);
                rowSizes[i] = (this._bitDepth * this._valuesPerPixel * rowLengths[i] + 7) / 8;
                rowCounts[i] = count!(r => canFind(r[], i))(pattern[]);
                rowCounts[i] *= height / 8;
                rowCounts[i] += count!(r => canFind(r[], i))(pattern[0 .. height % 8]);
            }
            this._uncompressedSize = sum(map!(i => adamLineSize(rowSizes[i]) * rowCounts[i])(iota(0,
                    7)));
            if (!this.readRawData())
            {
                this._rawData = null;
                return null;
            }
            assert(sum(map!(i => rowLengths[i] * rowCounts[i])(iota(0, 7))) == width * height);
            ubyte[][7] subImages;
            size_t index = 0;
            for (int i = 0; i < 7; i++)
            {
                size_t subSize = adamLineSize(rowSizes[i]) * rowCounts[i];
                subImages[i] = this._rawData[index .. index + subSize];
                index += subSize;
            }
            assert(index == this._rawData.length);
            this._rawData = null;
            for (int i = 0; i < 7; i++)
            {
                if (!this.unfilter(subImages[i], rowSizes[i], rowCounts[i]))
                {
                    return null;
                }
            }
            ubyte[] unlaced = new ubyte[(rowSize + 1) * height];
            if (bitsPerPixel < 8)
            {
                unlaced[] = 0;
            }
            size_t[7] subIndices;
            subIndices[] = 0;
            for (int y = 0; y < height; y++)
            {
                size_t rowIndex = (rowSize + 1) * y;
                unlaced[rowIndex] = FilterType.None;
                for (int x = 0; x < width; x++)
                {
                    int selSub = pattern[y % 8][x % 8];
                    size_t subX = subIndices[selSub] % rowLengths[selSub];
                    size_t subY = subIndices[selSub] / rowLengths[selSub];
                    assert(subImages[selSub][(rowSizes[selSub] + 1) * subY] == FilterType.None);
                    if (bitsPerPixel < 8)
                    {
                        ubyte val = subImages[selSub][(
                                    rowSizes[selSub] + 1) * subY + 1 + subX * bitsPerPixel / 8];
                        val >>= bitShift(bitsPerPixel, subX);
                        val &= 0xFF >> (8 - bitsPerPixel);
                        unlaced[rowIndex + 1 + x * bitsPerPixel / 8] |= val << bitShift(bitsPerPixel,
                                x);
                    }
                    else
                    {
                        size_t index1 = rowIndex + 1 + x * bitsPerPixel / 8;
                        size_t index2 = (rowSizes[selSub] + 1) * subY + 1 + subX * bitsPerPixel / 8;
                        unlaced[index1 .. index1 + bitsPerPixel / 8] = subImages[selSub][index2
                            .. index2 + bitsPerPixel / 8];
                    }
                    subIndices[selSub]++;
                }
            }
            assert(all!(i => subIndices[i] == rowLengths[i] * rowCounts[i])(iota(0, 7)));
            unfilteredData = unlaced;
        }
        else
        {
            this._uncompressedSize = (rowSize + 1) * height;
            if (!this.readRawData())
            {
                return null;
            }
            if (!this.unfilter(this._rawData, rowSize, height))
            {
                return null;
            }
            unfilteredData = this._rawData;
            this._rawData = null;
        }
        assert(unfilteredData.length == (rowSize + 1) * height);
        size_t dStride;
        void[] data = pixelDataAlloc(width, height, pixelFormat, dStride);
        final switch (this._colorType)
        {
        case ColorType.GrayscaleAlpha:
            for (int y = 0; y < height; y++)
            {
                for (int x = 0; x < width; x++)
                {
                    ubyte luma;
                    ubyte alpha;
                    if (this._bitDepth == 8)
                    {
                        luma = unfilteredData[(rowSize + 1) * y + x * 2 + 1];
                        alpha = unfilteredData[(rowSize + 1) * y + x * 2 + 2];
                    }
                    else
                    {
                        assert(this._bitDepth == 16);
                        luma = unfilteredData[(rowSize + 1) * y + x * 4 + 1];
                        alpha = unfilteredData[(rowSize + 1) * y + x * 4 + 3];
                    }
                    (cast(ubyte[4][]) data)[width * y + x] = [
                        luma, luma, luma, alpha
                    ];
                }
            }
            break;
        case ColorType.Indexed:
            if (this._bitDepth == 2)
            {
                (cast(ubyte[]) data)[] = 0;
                for (int y = 0; y < height; y++)
                {
                    for (int x = 0; x < width; x++)
                    {
                        ubyte val = unfilteredData[1 + (rowSize + 1) * y + x / 4] >> bitShift(2, x) & 0xFF
                            >> 6;
                        (cast(ubyte[]) data)[dStride * y + x / 2] |= val << bitShift(4, x);
                    }
                }
            }
            else
            {
                for (int y = 0; y < height; y++)
                {
                    data[dStride * y .. dStride * (y + 1)] = unfilteredData[1 + (
                                rowSize + 1) * y .. (rowSize + 1) * (y + 1)];
                }
            }
            break;
        case ColorType.Grayscale:
            if (pixelFormat == PixelFormat.Format32bppRgbaBE)
            {
                for (int y = 0; y < height; y++)
                {
                    for (int x = 0; x < width; x++)
                    {
                        ushort value;
                        Color color;
                        if (this._bitDepth < 8)
                        {
                            value = unfilteredData[1 + (rowSize + 1) * y + (x * this._bitDepth) / 8];
                            value >>= bitShift(this._bitDepth, x);
                            value &= 0xFF >> (8 - this._bitDepth);
                            color = Color.gray(fillByte(to!ubyte(value), this._bitDepth));
                        }
                        else if (this._bitDepth == 8)
                        {
                            value = unfilteredData[1 + (rowSize + 1) * y + x];
                            color = Color.gray(to!ubyte(value));
                        }
                        else
                        {
                            assert(this._bitDepth == 16);
                            size_t index = 1 + (rowSize + 1) * y + x * 2;
                            value = unfilteredData[index] << 8 | unfilteredData[index + 1];
                            color = Color.gray(value >> 8);
                        }
                        if (value == this._transparentColor[0])
                        {
                            color.a = 0;
                        }
                        (cast(ubyte[4][]) data)[width * y + x] = [
                            color.r, color.g, color.b, color.a
                        ];
                    }
                }
                break;
            }
            if (this._bitDepth < 8)
            {
                for (int y = 0; y < height; y++)
                {
                    for (int x = 0; x < width; x++)
                    {
                        ubyte value = unfilteredData[1 + (rowSize + 1) * y + (x * this._bitDepth) / 8];
                        value >>= bitShift(this._bitDepth, x);
                        value &= 0xFF >> (8 - this._bitDepth);
                        (cast(ubyte[]) data)[width * y + x] = fillByte(value, this._bitDepth);
                    }
                }
                break;
            }
            goto case;
        case ColorType.RgbTriple:
            if (pixelFormat == PixelFormat.Format32bppRgbaBE)
            {
                for (int y = 0; y < height; y++)
                {
                    for (int x = 0; x < width; x++)
                    {
                        ushort[3] rgb;
                        Color color;
                        if (this._bitDepth == 8)
                        {
                            rgb[0] = unfilteredData[1 + (rowSize + 1) * y + x * 3];
                            rgb[1] = unfilteredData[1 + (rowSize + 1) * y + x * 3 + 1];
                            rgb[2] = unfilteredData[1 + (rowSize + 1) * y + x * 3 + 2];
                            color = Color(to!ubyte(rgb[0]), to!ubyte(rgb[1]), to!ubyte(rgb[2]));
                        }
                        else
                        {
                            assert(this._bitDepth == 16);
                            size_t index = 1 + (rowSize + 1) * y + x * 6;
                            rgb[0] = unfilteredData[index] << 8 | unfilteredData[index + 1];
                            rgb[1] = unfilteredData[index + 2] << 8 | unfilteredData[index + 3];
                            rgb[2] = unfilteredData[index + 4] << 8 | unfilteredData[index + 5];
                            color = Color(rgb[0] >> 8, rgb[1] >> 8, rgb[2] >> 8);
                        }
                        if (rgb == this._transparentColor)
                        {
                            color.a = 0;
                        }
                        (cast(ubyte[4][]) data)[width * y + x] = [
                            color.r, color.g, color.b, color.a
                        ];
                    }
                }
                break;
            }
            goto case;
        case ColorType.Rgba:
            for (int y = 0; y < height; y++)
            {
                ubyte[] subArray = unfilteredData[1 + (rowSize + 1) * y .. (rowSize + 1) * (y + 1)];
                if (this._bitDepth == 8)
                {
                    data[dStride * y .. dStride * (y + 1)] = subArray;
                }
                else if (this._bitDepth == 16)
                {
                    data[dStride * y .. dStride * (y + 1)] = array(map!(i => subArray[i])(iota(0,
                            subArray.length, 2)));
                }
            }
            break;
        }
        Bitmap bmp = new Bitmap(width, height, 0, dStride, pixelFormat,
                assumeUnique(this._palette[]), false, data);
        static if (Animated)
        {
            this._frameIndex++;
            if (this._animated)
            {
                Bitmap slice = this._canvas.slice(this._frameRectangle);
                Bitmap prevSlice;
                bool lastFrame = this._frameIndex == this.length;
                if (!lastFrame && this._disposeOp == DisposeOp.APNG_DISPOSE_OP_PREVIOUS)
                {
                    prevSlice = new Bitmap(slice.width, slice.height, PixelFormat.Format32bppRgba);
                    prevSlice.copyFrom(slice);
                }
                if (this._blendOp == BlendOp.APNG_BLEND_OP_SOURCE)
                {
                    slice.copyFrom(bmp);
                }
                else
                {
                    assert(this._blendOp == BlendOp.APNG_BLEND_OP_OVER);
                    slice.blendFrom(bmp);
                }
                immutable(Color)[] palette = this._info.pixelFormat.indexed
                    ? assumeUnique(this._palette[]) : null;
                bmp = new Bitmap(this._info.width, this._info.height,
                        this._info.pixelFormat, palette);
                bmp.copyFrom(this._canvas);
                if (lastFrame)
                {
                    this._canvas = null;
                    do
                    {
                        ChunkHeader ch;
                        if (this._fp.rawRead((&ch)[0 .. 1]).length != 1)
                        {
                            return null;
                        }
                        ch = beConv(ch);
                        if (ch.type == "fcTL")
                        {
                            return null;
                        }
                        if (!this.processChunk(ch))
                        {
                            return null;
                        }
                    }
                    while (!this._fileEnd);
                    this._state = LoadState.End;
                }
                else
                {
                    if (this._disposeOp == DisposeOp.APNG_DISPOSE_OP_BACKGROUND)
                    {
                        slice.paint(Color(0, 0, 0, 0));
                        if (this._info.pixelFormat == PixelFormat.Format24bppRgbLE
                                || (this._info.pixelFormat.indexed
                                    && all!(c => c.a == 255)(this._palette)))
                        {
                            this._info.pixelFormat = PixelFormat.Format32bppArgbLE;
                        }
                    }
                    else if (this._disposeOp == DisposeOp.APNG_DISPOSE_OP_PREVIOUS)
                    {
                        slice.copyFrom(prevSlice);
                        this._info.pixelFormat = this._prevPixelFormat;
                    }
                    this._state = LoadState.BeforeInfo;
                }
            }
            else
            {
                this._state = LoadState.End;
            }
        }
        else
        {
            this._state = LoadState.End;
        }
        return bmp;
    }

    package(imaging.files) void skipImage()
    in (this.state == LoadState.BeforeImage || this.state == LoadState.BeforeInfo)
    {
        bool animated;
        static if (Animated)
        {
            animated = this._animated;
        }
        else
        {
            animated = false;
        }
        if (animated)
        {
            this.nextImage();
        }
        else
        {
            this._state = LoadState.Invalid;
            if (this.state == LoadState.BeforeInfo)
            {
                ubyte[8] signature;
                if (this._fp.rawRead(signature[]) != pngSignature)
                {
                    return;
                }
            }
            for (int i = 0; i < this._maxChunks; i++)
            {
                ChunkHeader ch;
                if (this._fp.rawRead((&ch)[0 .. 1]).length != 1)
                {
                    return;
                }
                ch = beConv(ch);
                if (!this.skipChunk(ch.type, ch.length))
                {
                    return;
                }
                if (ch.type == "IEND")
                {
                    if (ch.length == 0)
                    {
                        this._state = LoadState.End;
                    }
                    return;
                }
            }
        }
    }
}

/**
 * Represents an image loader for a Portable Network Graphics file.
 *
 * For an Animated PNG file, it will load the default static image of the animation.
 */
public final class PngLoader : ImageLoader
{
    private BasePngLoader!false _loader;

    /**
     * Creates an image loader for a Portable Network Graphics file.
     * Calling this constructor does not perform any read operation or advance the file pointer.
     *
     * Params:
     *     fp =
     *         The file pointer to be used.
     *         It must be open for binary read.
     *     maxChunks =
     *         The maximum amount of chunks to be read from the file.
     *         If the file has more chunks, it will be deemed to be invalid.
     */
    @trusted public this(File fp, int maxChunks = 1024)
    {
        this._loader = BasePngLoader!false(fp, PngFormat.instance(), maxChunks);
    }

    /// The instance of the [PngFormat] singleton class.
    @property @safe public PngFormat format() const nothrow
    {
        return PngFormat.instance();
    }

    /// The current state of the loader.
    @property @safe public pure LoadState state() const nothrow
    {
        return this._loader.state;
    }

    /// Always 1.
    @nogc @property @safe public pure int length() const nothrow
    {
        return this._loader.length;
    }

    /**
     * Tries to read information about the image in the file.
     * The [state] property must be equal to either [LoadState.BeforeInfo] or [LoadState.BeforeImage].
     * The function sets it to a value representing the new state of the loader.
     *
     * Returns:
     *     An [ImageInfo] instance if data is read correctly from the file.
     *     In this case the [state] property is set to [LoadState.BeforeImage].
     *     A null value if invalid data is encountered or the state is [LoadState.BeforeImage].
     *     In this case the [state] property is set to either [LoadState.Invalid] or [LoadState.End].
     */
    public Nullable!ImageInfo nextInfo()
    in (this.state == LoadState.BeforeInfo || this.state == LoadState.BeforeImage)
    {
        return this._loader.nextInfo();
    }

    /**
     * Tries to read the image in the file.
     * The [state] property must be equal to either [LoadState.BeforeInfo] or [LoadState.BeforeImage].
     * The function sets it to a value representing the new state of the loader.
     *
     * Returns:
     *     A [Bitmap] instance if data is read correctly from the file.
     *     In this case the [state] property is set to [LoadState.End].
     *     A null value if invalid data is encountered.
     *     In this case the [state] property is set to [LoadState.Invalid].
     */
    public Bitmap nextImage()
    in (this.state == LoadState.BeforeImage || this.state == LoadState.BeforeInfo)
    {
        return this._loader.nextImage();
    }

    /**
     * Skips the image in the file.
     * The [state] property must be equal to either [LoadState.BeforeInfo] or [LoadState.BeforeImage].
     * The function sets it to a either [LoadState.End] or [LoadState.Invalid].
     */
    public void skipImage()
    in (this.state == LoadState.BeforeImage || this.state == LoadState.BeforeInfo)
    out (; this.state == LoadState.End || LoadState.Invalid)
    {
        this._loader.skipImage();
    }
}

package(imaging.files) void writeChunk(T)(File fp, ChunkType type, T data)
{
    static if (is(T : E[], E))
    {
        uint length = to!uint(E.sizeof * data.length);
        static if (!is(E == void))
        {
            data = array(map!(d => beConv(d))(data));
        }
    }
    else
    {
        uint length = T.sizeof;
        data = beConv(data);
    }
    ChunkHeader header = ChunkHeader(length, type);
    header = beConv(header);
    fp.rawWrite([header]);
    uint crc = crc32(0, type);
    static if (isArray!T)
    {
        fp.rawWrite(data);
        crc = crc32(crc, data);
    }
    else
    {
        fp.rawWrite([data]);
        crc = crc32(crc, [data]);
    }
    crc = beConv(crc);
    fp.rawWrite([crc]);
}

package(imaging.files) ubyte[] encode(const Bitmap bmp, ColorType colorType, int bitDepth)
{
    PixelFormat format;
    immutable(Color)[] palette = null;
    void[] row;
    final switch (colorType)
    {
    case ColorType.Grayscale:
        format = PixelFormat.Format8bppGray;
        row = new ubyte[bmp.width];
        break;
    case ColorType.RgbTriple:
        format = PixelFormat.Format24bppRgbBE;
        row = new ubyte[bmp.width * 3];
        break;
    case ColorType.Indexed:
        if (bitDepth == 1)
        {
            format = PixelFormat.Format1bppIndexed;
        }
        else if (bitDepth == 4)
        {
            format = PixelFormat.Format4bppIndexed;
        }
        else
        {
            format = PixelFormat.Format8bppIndexed;
        }
        format = bmp.pixelFormat;
        palette = bmp.palette;
        row = new ubyte[(bmp.width * format.bpp + 7) / 8];
        break;
    case ColorType.GrayscaleAlpha:
        assert(0);
    case ColorType.Rgba:
        format = PixelFormat.Format32bppRgbaBE;
        row = new uint[bmp.width];
        break;
    }
    ubyte[] data = new ubyte[(row.length + 1) * bmp.height];
    size_t index = 0;
    foreach (int y; bmp.yTopDown)
    {
        data[index++] = FilterType.None;
        if (bmp.bpp < 8)
        {
            data[index + row.length - 1] = 0;
        }
        bmp.rawLine(y, row.ptr, 0, format, palette);
        data[index .. index + row.length] = cast(ubyte[]) row;
        index += row.length;
    }
    return data;
}

/**
 * Represents the Portable Network Graphics format.
 */
public final class PngFormat : SingleImageFormat
{
    private static PngFormat _instance;

    @safe private pure this() nothrow
    {
    }

    /**
     * Returns the instance of the singleton [PngFormat] class.
     *
     * Returns: The singular instance of this class.
     */
    @safe public static PngFormat instance() nothrow
    {
        if (_instance is null)
        {
            _instance = new PngFormat();
        }
        return _instance;
    }

    /**
     * Checks whether a file is a Portable Network Graphics file, based on its first bytes.
     * Because Animated PNG files are also valid PNG files (decoding to their default static image), this will return `true` for them.
     *
     * Params:
     *     head = The beginning of the file.
     *
     * Returns:
     *     `true` if the file is a Portable Network Graphics file, `false` otherwise.
     *     If not enough bytes are provided, `false` is returned.
     */
    @nogc @safe public override bool checkFormat(const ubyte[] head) const nothrow
    {
        return head[0 .. 8] == pngSignature;
    }

    /**
     * Creates an image loader for the given file.
     * Calling this function does not perform any read operation or advance the file pointer.
     *
     * Prams:
     *     fp =
     *         The file pointer to be used.
     *         It must be open for binary read.
     *         It must refer to a file in this format and point to its beginning.
     *         The image file may be part of a larger file.
     *         Any data preceding to the file pointer is ignored.
     *
     * Returns: The created image loader.
     */
    @safe public override PngLoader loader(File fp) const
    {
        return new PngLoader(fp);
    }

    /**
     * Exports the given image to the given Portable Network Graphics file.
     * After the operation, the given file pointer is set to the end of the written data (also the end of the file).
     *
     * Params:
     *     fp =
     *         The file pointer to be used.
     *         It must be open for binary write.
     *         Any data preceding the file pointer is left untouched.
     *     bmp =
     *         The image to be exported.
     *         It cannot be null.
     */
    public override void save(File fp, const Bitmap bmp) const
    in (bmp !is null)
    {
        enforce(bmp.valid());
        fp.rawWrite(pngSignature);
        ubyte bitDepth = 8;
        ColorType colorType;
        switch (bmp.pixelFormat)
        {
        case PixelFormat.Format1bppIndexed, PixelFormat.Format4bppIndexed,
                PixelFormat.Format8bppIndexed:
                bitDepth = to!ubyte(bmp.bpp);
            colorType = ColorType.Indexed;
            break;
        case PixelFormat.Format8bppGray:
            colorType = ColorType.Grayscale;
            break;
        case PixelFormat.Format32bppArgbBE, PixelFormat.Format32bppArgbLE,
                PixelFormat.Format32bppRgbaBE, PixelFormat.Format32bppRgbaLE:
                colorType = ColorType.Rgba;
            break;
        default:
            colorType = ColorType.RgbTriple;
            break;
        }
        Data_IHDR d_IHDR = Data_IHDR(bmp.width, bmp.height, bitDepth, colorType, 0, 0, 0);
        assert(d_IHDR.valid);
        writeChunk(fp, "IHDR", d_IHDR);
        if (bmp.indexed)
        {
            ubyte[3][] d_PLTE = new ubyte[3][bmp.palette.length];
            int lastAlpha = -1;
            for (int i = 0; i < bmp.palette.length; i++)
            {
                d_PLTE[i] = [
                    bmp.palette[i].r, bmp.palette[i].g, bmp.palette[i].b
                ];
                if (bmp.palette[i].a != 255)
                {
                    lastAlpha = i;
                }
            }
            writeChunk(fp, "PLTE", d_PLTE);
            if (lastAlpha != -1)
            {
                ubyte[] d_tRNS = new ubyte[lastAlpha + 1];
                for (int i = 0; i <= lastAlpha; i++)
                {
                    d_tRNS[i] = bmp.palette[i].a;
                }
                writeChunk(fp, "tRNS", d_tRNS);
            }
            size_t[] counts = bmp.indexCounts();
            ushort[] d_hIST = new ushort[counts.length];
            size_t maxCount = maxElement(counts);
            if (maxCount < ushort.max)
            {
                for (int i = 0; i < d_hIST.length; i++)
                {
                    d_hIST[i] = cast(ushort) counts[i];
                }
            }
            else
            {
                int p = 0;
                while (maxCount > 1 << 16)
                {
                    p++;
                    maxCount >>= 1;
                }
                assert(p > 0);
                for (int i = 0; i < d_hIST.length; i++)
                {
                    size_t val = counts[i] >> p;
                    if (counts[i] > 0 && val == 0)
                    {
                        val = 1;
                    }
                    d_hIST[i] = cast(ushort) val;
                }
            }
            writeChunk(fp, "hIST", d_hIST);
        }
        ubyte[] data = encode(bmp, colorType, bitDepth);
        ubyte[] d_IDAT = compress(data);
        writeChunk(fp, "IDAT", d_IDAT);
        writeChunk(fp, "IEND", []);
    }
}

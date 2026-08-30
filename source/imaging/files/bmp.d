/**
 * This module provides a codec for the Windows Bitmap Format for device-independent bitmaps.
 *
 * See_Also:
 *     [[MS-WMF]: Windows Metafile Format](https://learn.microsoft.com/openspecs/windows_protocols/ms-wmf/4813e7fd-52d0-4f42-965f-228c8b7488d2),
 *     [DIBs and Their Use](https://learn.microsoft.com/previous-versions/ms969901(v=msdn.10)),
 *     [BMP](https://learn.microsoft.com/dotnet/desktop/winforms/advanced/types-of-bitmaps#bmp),
 *     [BMP Format Overview](https://learn.microsoft.com/windows/win32/wic/bmp-format-overview)
 *
 * Copyright: Copyright (C) 2026 Valentino Giudice
 * License: BSL-1.0
 * Authors: [Valentino Giudice](https://www.functorfault.net/)
 */
module imaging.files.bmp;

import imaging : Bitmap, bpp, Color, getPixelDataSize, indexed, pixelDataAlloc, PixelFormat;
import imaging.files : ImageFormat, ImageInfo, ImageLoader, leConv, LoadState, SingleImageFormat;
import std.algorithm.comparison : among, min;
import std.algorithm.mutation : swapRanges;
import std.algorithm.searching : any;
import std.exception : assumeUnique, enforce;
import std.math.algebraic : abs;
import std.range : iota;
import std.stdio : File, SEEK_CUR;
import std.traits : EnumMembers;
import std.typecons : Nullable, nullable;

version (Windows)
{
    import core.sys.windows.wingdi : BI_BITFIELDS, BI_RGB, BITMAPCOREHEADER, BITMAPFILEHEADER, BITMAPINFOHEADER,
        BITMAPV4HEADER, BITMAPV5HEADER, CIEXYZ, CIEXYZTRIPLE, FXPT2DOT30, RGBQUAD, RGBTRIPLE;
}
else
{
    private enum : uint
    {
        BI_RGB = 0,
        BI_RLE8,
        BI_RLE4,
        BI_BITFIELDS,
        BI_JPEG,
        BI_PNG
    }

    private struct BITMAPCOREHEADER
    {
        uint bcSize;
        ushort bcWidth;
        ushort bcHeight;
        ushort bcPlanes;
        ushort bcBitCount;
    }

    private struct BITMAPFILEHEADER
    {
    align(2):
        ushort bfType;
        uint bfSize;
        ushort bfReserved1;
        ushort bfReserved2;
        uint bfOffBits;
    }

    package(imaging.files) struct BITMAPINFOHEADER
    {
        uint biSize;
        int biWidth;
        int biHeight;
        ushort biPlanes;
        ushort biBitCount;
        uint biCompression;
        uint biSizeImage;
        int biXPelsPerMeter;
        int biYPelsPerMeter;
        uint biClrUsed;
        uint biClrImportant;
    }

    private struct BITMAPV4HEADER
    {
        uint bV4Size;
        int bV4Width;
        int bV4Height;
        ushort bV4Planes;
        ushort bV4BitCount;
        uint bV4V4Compression;
        uint bV4SizeImage;
        int bV4XPelsPerMeter;
        int bV4YPelsPerMeter;
        uint bV4ClrUsed;
        uint bV4ClrImportant;
        uint bV4RedMask;
        uint bV4GreenMask;
        uint bV4BlueMask;
        uint bV4AlphaMask;
        uint bV4CSType;
        CIEXYZTRIPLE bV4Endpoints;
        uint bV4GammaRed;
        uint bV4GammaGreen;
        uint bV4GammaBlue;
    }

    private struct BITMAPV5HEADER
    {
        uint bV5Size;
        int bV5Width;
        int bV5Height;
        ushort bV5Planes;
        ushort bV5BitCount;
        uint bV5Compression;
        uint bV5SizeImage;
        int bV5XPelsPerMeter;
        int bV5YPelsPerMeter;
        uint bV5ClrUsed;
        uint bV5ClrImportant;
        uint bV5RedMask;
        uint bV5GreenMask;
        uint bV5BlueMask;
        uint bV5AlphaMask;
        uint bV5CSType;
        CIEXYZTRIPLE bV5Endpoints;
        uint bV5GammaRed;
        uint bV5GammaGreen;
        uint bV5GammaBlue;
        uint bV5Intent;
        uint bV5ProfileData;
        uint bV5ProfileSize;
        uint bV5Reserved;
    }

    private struct CIEXYZ
    {
        FXPT2DOT30 ciexyzX;
        FXPT2DOT30 ciexyzY;
        FXPT2DOT30 ciexyzZ;
    }

    private struct CIEXYZTRIPLE
    {
        CIEXYZ ciexyzRed;
        CIEXYZ ciexyzGreen;
        CIEXYZ ciexyzBlue;
    }

    private alias FXPT2DOT30 = int;

    package struct RGBQUAD
    {
        ubyte rgbBlue;
        ubyte rgbGreen;
        ubyte rgbRed;
        ubyte rgbReserved;
    }

    private struct RGBTRIPLE
    {
        ubyte rgbtBlue;
        ubyte rgbtGreen;
        ubyte rgbtRed;
    }
}

// https://graphics.stanford.edu/~seander/bithacks.html#ZerosOnRightParallel
private int rightZeros(uint v)
{
    uint c = 32;
    v &= -(cast(int) v);
    if (v)
        c--;
    if (v & 0x0000FFFF)
        c -= 16;
    if (v & 0x00FF00FF)
        c -= 8;
    if (v & 0x0F0F0F0F)
        c -= 4;
    if (v & 0x33333333)
        c -= 2;
    if (v & 0x55555555)
        c -= 1;
    return c;
}

private bool validMask(uint v)
{
    if (v == 0)
    {
        return false;
    }
    v >>= rightZeros(v);
    v++;
    return v && !(v & (v - 1));
}

private ubyte applyMask(uint value, int shift, int count)
{
    uint masked = value >> shift;
    if (count == 8)
    {
        return cast(ubyte) masked;
    }
    if (count < 8)
    {
        masked &= (1 << count) - 1;
        ubyte result = 0;
        shift = 8;
        while (shift > 0)
        {
            result |= masked << shift;
            shift -= count;
        }
        result |= masked >> (-shift);
        return result;
    }
    return cast(ubyte)(masked >> (count - 8));
}

private size_t computeStride(int width, int bpp)
{
    return ((width * bpp + 31) & ~31) >> 3;
}

private FXPT2DOT30 toFxpt2dot30(double value)
{
    return cast(FXPT2DOT30)(value * (1 << 30) + 0.5);
}

private enum Compression : uint
{
    BI_RGB = 0x0000,
    BI_RLE8 = 0x0001,
    BI_RLE4 = 0x0002,
    BI_BITFIELDS = 0x0003,
    BI_JPEG = 0x0004,
    BI_PNG = 0x0005,
    BI_CMYK = 0x000B,
    BI_CMYKRLE8 = 0x000C,
    BI_CMYKRLE4 = 0x000D
}

private uint strToUint(string str)
{
    return str[0] << 24 | str[1] << 16 | str[2] << 8 | str[3];
}

private enum LogicalColorSpace : uint
{
    LCS_CALIBRATED_RGB = 0x00000000,
    LCS_sRGB = strToUint("sRGB"),
    LCS_WINDOWS_COLOR_SPACE = strToUint("Win "),
    PROFILE_LINKED = strToUint("LINK"),
    PROFILE_EMBEDDED = strToUint("MBED")
}

private enum GamutMappingIntent : uint
{
    LCS_GM_ABS_COLORIMETRIC = 0x00000008,
    LCS_GM_BUSINESS = 0x00000001,
    LCS_GM_GRAPHICS = 0x00000002,
    LCS_GM_IMAGES = 0x00000004
}

/**
 * Represents an image loader for a file in the Windows Bitmap Format for device-independent bitmaps.
 */
public final class BmpLoader : ImageLoader
{
    private File _fp;
    private LoadState _state;
    private ImageInfo _info;
    private ushort _bitCount;
    private Compression _compression;
    private size_t _fStride;
    private size_t _imageSize;
    private bool _reversed;
    private uint[4] _masks;
    private bool _useMasks;
    private Color[] _palette;
    private ImageLoader _innerLoader;

    /**
     * Creates an image loader for a file in the Windows Bitmap Format for device-independent bitmaps.
     * Calling this constructor does not perform any read operation or advance the file pointer.
     *
     * Params:
     *     fp =
     *         The file pointer to be used.
     *         It must be open for binary read.
     */
    @safe public this(File fp)
    {
        this._state = LoadState.BeforeInfo;
        this._fp = fp;
    }

    /// The instance of the [BmpFormat] singleton class.
    @property @safe public BmpFormat format() const nothrow
    {
        return BmpFormat.instance();
    }

    /// The current state of the loader.
    @nogc @property @safe public pure LoadState state() const nothrow
    {
        return this._state;
    }

    /// Always 1.
    @nogc @property @safe public pure int length() const nothrow
    out (result; result == 1)
    {
        return 1;
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
        if (this.state == LoadState.BeforeImage)
        {
            this._state = LoadState.End;
            return Nullable!ImageInfo();
        }
        assert(this.state == LoadState.BeforeInfo);
        this._state = LoadState.Invalid;
        BITMAPFILEHEADER fHeader;
        if (this._fp.rawRead((&fHeader)[0 .. 1]).length != 1)
        {
            return Nullable!ImageInfo();
        }
        fHeader = leConv(fHeader);
        if (fHeader.bfType != ('B' | 'M' << 8))
        {
            return Nullable!ImageInfo();
        }
        if (fHeader.bfReserved1 != 0 || fHeader.bfReserved2 != 0)
        {
            return Nullable!ImageInfo();
        }
        uint headerSize;
        if (this._fp.rawRead((&headerSize)[0 .. 1]).length != 1)
        {
            return Nullable!ImageInfo();
        }
        headerSize = leConv(headerSize);
        int width;
        int height;
        int xPelsPerMeter;
        int yPelsPerMeter;
        uint crlUsed;
        int rgbSize = 4;
        bool readMasks = false;
        LogicalColorSpace colorSpace;
        CIEXYZTRIPLE endpoints;
        uint[3] gamma;
        uint additionalOffset = 0;
        this._innerLoader = null;
        switch (headerSize)
        {
        case BITMAPCOREHEADER.sizeof:
            BITMAPCOREHEADER bcHeader;
            bcHeader.bcSize = BITMAPCOREHEADER.sizeof;
            if (this._fp.rawRead((cast(void*)&bcHeader)[4 .. BITMAPCOREHEADER.sizeof])
                    .length != BITMAPCOREHEADER.sizeof - 4)
            {
                return Nullable!ImageInfo();
            }
            bcHeader = leConv(bcHeader);
            if (bcHeader.bcWidth <= 0 || bcHeader.bcHeight <= 0)
            {
                return Nullable!ImageInfo();
            }
            if (bcHeader.bcPlanes != 1)
            {
                return Nullable!ImageInfo();
            }
            if (!among!(1, 4, 8, 24)(bcHeader.bcBitCount))
            {
                return Nullable!ImageInfo();
            }
            width = bcHeader.bcWidth;
            height = bcHeader.bcHeight;
            this._reversed = true;
            this._bitCount = bcHeader.bcBitCount;
            this._fStride = computeStride(width, this._bitCount);
            this._compression = Compression.BI_RGB;
            if (fHeader.bfSize != fHeader.bfOffBits + this._fStride * height
                    && fHeader.bfSize != BITMAPFILEHEADER.sizeof + BITMAPCOREHEADER.sizeof)
            {
                return Nullable!ImageInfo();
            }
            xPelsPerMeter = 0;
            yPelsPerMeter = 0;
            uint offsetSize = cast(uint)(
                    fHeader.bfOffBits - BITMAPFILEHEADER.sizeof - BITMAPCOREHEADER.sizeof);
            if (bcHeader.bcBitCount <= 8)
            {
                if (offsetSize == 0)
                {
                    return Nullable!ImageInfo();
                }
            }
            else if (offsetSize != 0)
            {
                return Nullable!ImageInfo();
            }
            if (offsetSize % 3 != 0)
            {
                return Nullable!ImageInfo();
            }
            crlUsed = offsetSize / 3;
            rgbSize = 3;
            break;
        case BITMAPINFOHEADER.sizeof:
            BITMAPINFOHEADER biHeader;
            biHeader.biSize = BITMAPINFOHEADER.sizeof;
            if (this._fp.rawRead((cast(void*)&biHeader)[4 .. BITMAPINFOHEADER.sizeof])
                    .length != BITMAPINFOHEADER.sizeof - 4)
            {
                return Nullable!ImageInfo();
            }
            biHeader = leConv(biHeader);
            width = biHeader.biWidth;
            height = abs(biHeader.biHeight);
            this._reversed = biHeader.biHeight > 0;
            this._bitCount = biHeader.biBitCount;
            if (biHeader.biPlanes != 1)
            {
                return Nullable!ImageInfo();
            }
            if (!among!(Compression.BI_RGB, Compression.BI_RLE8,
                    Compression.BI_RLE4, Compression.BI_BITFIELDS)(biHeader.biCompression))
            {
                return Nullable!ImageInfo();
            }
            this._compression = cast(Compression) biHeader.biCompression;
            if (this._compression == Compression.BI_RGB
                    || this._compression == Compression.BI_BITFIELDS)
            {
                this._fStride = computeStride(width, this._bitCount);
                if (biHeader.biSizeImage != 0 && biHeader.biSizeImage != this._fStride * height)
                {
                    return Nullable!ImageInfo();
                }
                if (fHeader.bfSize != fHeader.bfOffBits + this._fStride * height
                        && fHeader.bfSize != BITMAPFILEHEADER.sizeof + BITMAPINFOHEADER.sizeof)
                {
                    return Nullable!ImageInfo();
                }
                this._imageSize = this._fStride * height;
            }
            else if (this._compression == Compression.BI_RLE8
                    || this._compression == Compression.BI_RLE4)
            {
                if (!this._reversed)
                {
                    return Nullable!ImageInfo();
                }
                if (biHeader.biSizeImage == 0)
                {
                    return Nullable!ImageInfo();
                }
                if (fHeader.bfSize != fHeader.bfOffBits + biHeader.biSizeImage)
                {
                    return Nullable!ImageInfo();
                }
                this._imageSize = biHeader.biSizeImage;
            }
            if (this._compression == Compression.BI_BITFIELDS)
            {
                readMasks = true;
            }
            xPelsPerMeter = biHeader.biXPelsPerMeter;
            yPelsPerMeter = biHeader.biYPelsPerMeter;
            crlUsed = biHeader.biClrUsed;
            if (biHeader.biClrImportant > crlUsed)
            {
                return Nullable!ImageInfo();
            }
            break;
        case BITMAPV4HEADER.sizeof:
            BITMAPV4HEADER bV4Header;
            bV4Header.bV4Size = BITMAPV4HEADER.sizeof;
            if (this._fp.rawRead((cast(void*)&bV4Header)[4 .. BITMAPV4HEADER.sizeof])
                    .length != BITMAPV4HEADER.sizeof - 4)
            {
                return Nullable!ImageInfo();
            }
            bV4Header = leConv(bV4Header);
            if (fHeader.bfSize != fHeader.bfOffBits + bV4Header.bV4SizeImage)
            {
                return Nullable!ImageInfo();
            }
            if (bV4Header.bV4Width <= 0 || bV4Header.bV4Height == 0)
            {
                return Nullable!ImageInfo();
            }
            if (bV4Header.bV4Planes != 1)
            {
                return Nullable!ImageInfo();
            }
            if (!among!(0, 1, 2, 4, 8, 16, 24, 32)(bV4Header.bV4BitCount))
            {
                return Nullable!ImageInfo();
            }
            if (!among!(Compression.BI_RGB, Compression.BI_RLE8, Compression.BI_RLE4,
                    Compression.BI_BITFIELDS, Compression.BI_JPEG, Compression.BI_PNG)(
                    bV4Header.bV4V4Compression))
            {
                return Nullable!ImageInfo();
            }
            width = bV4Header.bV4Width;
            height = abs(bV4Header.bV4Height);
            this._reversed = bV4Header.bV4Height > 0;
            this._bitCount = bV4Header.bV4BitCount;
            this._fStride = computeStride(width, this._bitCount);
            this._compression = cast(Compression) bV4Header.bV4V4Compression;
            if (this._compression == Compression.BI_RGB
                    || this._compression == Compression.BI_BITFIELDS)
            {
                this._fStride = computeStride(width, this._bitCount);
                if (bV4Header.bV4SizeImage != 0 && bV4Header.bV4SizeImage != this._fStride * height)
                {
                    return Nullable!ImageInfo();
                }
                if (fHeader.bfSize != fHeader.bfOffBits + this._fStride * height
                        && fHeader.bfSize != BITMAPFILEHEADER.sizeof + BITMAPINFOHEADER.sizeof)
                {
                    return Nullable!ImageInfo();
                }
                this._imageSize = this._fStride * height;
            }
            else if (this._compression == Compression.BI_RLE8
                    || this._compression == Compression.BI_RLE4)
            {
                if (!this._reversed)
                {
                    return Nullable!ImageInfo();
                }
                if (bV4Header.bV4SizeImage == 0)
                {
                    return Nullable!ImageInfo();
                }
                if (fHeader.bfSize != fHeader.bfOffBits + bV4Header.bV4SizeImage)
                {
                    return Nullable!ImageInfo();
                }
                this._imageSize = bV4Header.bV4SizeImage;
            }
            if (this._compression == Compression.BI_PNG)
            {
                this._imageSize = bV4Header.bV4SizeImage;
            }
            else if (bV4Header.bV4SizeImage != this._fStride * height)
            {
                return Nullable!ImageInfo();
            }
            xPelsPerMeter = bV4Header.bV4XPelsPerMeter;
            yPelsPerMeter = bV4Header.bV4YPelsPerMeter;
            crlUsed = bV4Header.bV4ClrUsed;
            if (bV4Header.bV4ClrImportant > crlUsed)
            {
                return Nullable!ImageInfo();
            }
            if (this._compression == Compression.BI_BITFIELDS)
            {
                this._masks = [
                    bV4Header.bV4RedMask, bV4Header.bV4GreenMask,
                    bV4Header.bV4BlueMask, bV4Header.bV4AlphaMask
                ];
            }
            if (!among!(EnumMembers!LogicalColorSpace)(bV4Header.bV4CSType))
            {
                return Nullable!ImageInfo();
            }
            colorSpace = cast(LogicalColorSpace) bV4Header.bV4CSType;
            if (this._compression == Compression.BI_PNG)
            {
                if (colorSpace != LogicalColorSpace.LCS_sRGB
                        && LogicalColorSpace.LCS_WINDOWS_COLOR_SPACE)
                {
                    return Nullable!ImageInfo();
                }
            }
            else if (colorSpace == LogicalColorSpace.LCS_CALIBRATED_RGB)
            {
                endpoints = bV4Header.bV4Endpoints;
                gamma = [
                    bV4Header.bV4GammaRed, bV4Header.bV4GammaGreen,
                    bV4Header.bV4GammaBlue
                ];
            }
            break;
        case BITMAPV5HEADER.sizeof:
            BITMAPV5HEADER bV5Header;
            bV5Header.bV5Size = BITMAPV5HEADER.sizeof;
            if (this._fp.rawRead((cast(void*)&bV5Header)[4 .. BITMAPV5HEADER.sizeof])
                    .length != BITMAPV5HEADER.sizeof - 4)
            {
                return Nullable!ImageInfo();
            }
            bV5Header = leConv(bV5Header);
            if (fHeader.bfSize != fHeader.bfOffBits + bV5Header.bV5SizeImage)
            {
                return Nullable!ImageInfo();
            }
            if (bV5Header.bV5Width <= 0 || bV5Header.bV5Height == 0)
            {
                return Nullable!ImageInfo();
            }
            if (bV5Header.bV5Planes != 1)
            {
                return Nullable!ImageInfo();
            }
            if (!among!(0, 1, 2, 4, 8, 16, 24, 32)(bV5Header.bV5BitCount))
            {
                return Nullable!ImageInfo();
            }
            if (!among!(Compression.BI_RGB, Compression.BI_RLE8, Compression.BI_RLE4,
                    Compression.BI_BITFIELDS, Compression.BI_JPEG, Compression.BI_PNG)(
                    bV5Header.bV5Compression))
            {
                return Nullable!ImageInfo();
            }
            width = bV5Header.bV5Width;
            height = abs(bV5Header.bV5Height);
            this._reversed = bV5Header.bV5Height > 0;
            this._bitCount = bV5Header.bV5BitCount;
            this._fStride = computeStride(width, this._bitCount);
            this._compression = cast(Compression) bV5Header.bV5Compression;
            if (this._compression == Compression.BI_RGB
                    || this._compression == Compression.BI_BITFIELDS)
            {
                this._fStride = computeStride(width, this._bitCount);
                if (bV5Header.bV5SizeImage != 0 && bV5Header.bV5SizeImage != this._fStride * height)
                {
                    return Nullable!ImageInfo();
                }
                if (fHeader.bfSize != fHeader.bfOffBits + this._fStride * height
                        && fHeader.bfSize != BITMAPFILEHEADER.sizeof + BITMAPINFOHEADER.sizeof)
                {
                    return Nullable!ImageInfo();
                }
                this._imageSize = this._fStride * height;
            }
            else if (this._compression == Compression.BI_RLE8
                    || this._compression == Compression.BI_RLE4)
            {
                if (!this._reversed)
                {
                    return Nullable!ImageInfo();
                }
                if (bV5Header.bV5SizeImage == 0)
                {
                    return Nullable!ImageInfo();
                }
                if (fHeader.bfSize != fHeader.bfOffBits + bV5Header.bV5SizeImage)
                {
                    return Nullable!ImageInfo();
                }
                this._imageSize = bV5Header.bV5SizeImage;
            }
            if (this._compression == Compression.BI_PNG)
            {
                this._imageSize = bV5Header.bV5SizeImage;
            }
            else if (bV5Header.bV5SizeImage != this._fStride * height)
            {
                return Nullable!ImageInfo();
            }
            xPelsPerMeter = bV5Header.bV5XPelsPerMeter;
            yPelsPerMeter = bV5Header.bV5YPelsPerMeter;
            crlUsed = bV5Header.bV5ClrUsed;
            if (bV5Header.bV5ClrImportant > crlUsed)
            {
                return Nullable!ImageInfo();
            }
            if (this._compression == Compression.BI_BITFIELDS)
            {
                this._masks = [
                    bV5Header.bV5RedMask, bV5Header.bV5GreenMask,
                    bV5Header.bV5BlueMask, bV5Header.bV5AlphaMask
                ];
            }
            if (!among!(EnumMembers!LogicalColorSpace)(bV5Header.bV5CSType))
            {
                return Nullable!ImageInfo();
            }
            colorSpace = cast(LogicalColorSpace) bV5Header.bV5CSType;
            if (this._compression == Compression.BI_PNG)
            {
                if (colorSpace != LogicalColorSpace.LCS_sRGB
                        && LogicalColorSpace.LCS_WINDOWS_COLOR_SPACE)
                {
                    return Nullable!ImageInfo();
                }
            }
            else if (colorSpace == LogicalColorSpace.LCS_CALIBRATED_RGB)
            {
                endpoints = bV5Header.bV5Endpoints;
                gamma = [
                    bV5Header.bV5GammaRed, bV5Header.bV5GammaGreen,
                    bV5Header.bV5GammaBlue
                ];
            }
            if (!among!(EnumMembers!GamutMappingIntent)(bV5Header.bV5Intent))
            {
                return Nullable!ImageInfo();
            }
            if (bV5Header.bV5Reserved != 0)
            {
                return Nullable!ImageInfo();
            }
            break;
        default:
            return Nullable!ImageInfo();
        }
        if (width <= 0 || height == 0)
        {
            return Nullable!ImageInfo();
        }
        if (this._compression == Compression.BI_PNG)
        {
            if (this._bitCount != 0)
            {
                return Nullable!ImageInfo();
            }
            this._innerLoader = ImageFormat.png.loader(this._fp);
            ulong p = this._fp.tell;
            Nullable!ImageInfo info = this._innerLoader.nextInfo();
            if (this._innerLoader.state == LoadState.Invalid)
            {
                return Nullable!ImageInfo();
            }
            assert(!info.isNull);
            if (this._imageSize != 0)
            {
                ulong shift = this._fp.tell - p;
                if (shift >= this._imageSize)
                {
                    return Nullable!ImageInfo();
                }
                this._imageSize -= shift;
            }
            if (info.get.width != width || info.get.height != height)
            {
                return Nullable!ImageInfo();
            }
            this._info = ImageInfo(BmpFormat.instance(), width, height, info.get.pixelFormat);
            this._state = LoadState.BeforeImage;
            return nullable(this._info);
        }
        if (!among!(1, 2, 4, 8, 16, 24, 32)(this._bitCount))
        {
            return Nullable!ImageInfo();
        }
        if (this._compression == Compression.BI_BITFIELDS
                && this._bitCount != 16 && this._bitCount != 32)
        {
            return Nullable!ImageInfo();
        }
        if (this._compression == Compression.BI_RLE4 && this._bitCount != 4)
        {
            return Nullable!ImageInfo();
        }
        if (this._compression == Compression.BI_RLE8 && this._bitCount != 8)
        {
            return Nullable!ImageInfo();
        }
        if (colorSpace == LogicalColorSpace.PROFILE_LINKED)
        {
            return Nullable!ImageInfo();
        }
        if (xPelsPerMeter < 0 || yPelsPerMeter < 0)
        {
            return Nullable!ImageInfo();
        }
        if (xPelsPerMeter != 0 && yPelsPerMeter != 0
                && (xPelsPerMeter >> 10 > yPelsPerMeter || yPelsPerMeter >> 10 > xPelsPerMeter))
        {
            return Nullable!ImageInfo();
        }
        PixelFormat pixelFormat;
        int paletteSize;
        if (this._bitCount <= 8)
        {
            if (0 < crlUsed && crlUsed <= 1 << this._bitCount)
            {
                paletteSize = crlUsed;
            }
            else
            {
                paletteSize = 1 << this._bitCount;
            }
        }
        else
        {
            paletteSize = crlUsed;
        }
        switch (this._compression)
        {
        case Compression.BI_RGB, Compression.BI_RLE4, Compression.BI_RLE8:
            if (fHeader.bfOffBits < BITMAPFILEHEADER.sizeof + headerSize + paletteSize * rgbSize)
            {
                return Nullable!ImageInfo();
            }
            additionalOffset = cast(uint)(fHeader.bfOffBits - (
                    BITMAPFILEHEADER.sizeof + headerSize + paletteSize * rgbSize));
            if (paletteSize == 0)
            {
                this._palette = null;
            }
            else if (this._bitCount <= 8)
            {
                this._palette = new Color[paletteSize];
                if (rgbSize == 4)
                {
                    for (int i = 0; i < paletteSize; i++)
                    {
                        RGBQUAD quad;
                        if (this._fp.rawRead((&quad)[0 .. 1]).length != 1)
                        {
                            return Nullable!ImageInfo();
                        }
                        if (quad.rgbReserved != 0)
                        {
                            return Nullable!ImageInfo();
                        }
                        this._palette[i] = Color(quad.rgbRed, quad.rgbGreen, quad.rgbBlue);
                    }
                }
                else
                {
                    for (int i = 0; i < paletteSize; i++)
                    {
                        RGBTRIPLE triple;
                        if (this._fp.rawRead((&triple)[0 .. 1]).length != 1)
                        {
                            return Nullable!ImageInfo();
                        }
                        this._palette[i] = Color(triple.rgbtRed, triple.rgbtGreen, triple.rgbtBlue);
                    }
                }
            }
            else
            {
                this._palette = null;
                for (int i = 0; i < paletteSize; i++)
                {
                    RGBQUAD quad;
                    if (this._fp.rawRead((&quad)[0 .. 1]).length != 1)
                    {
                        return Nullable!ImageInfo();
                    }
                    if (quad.rgbReserved != 0)
                    {
                        return Nullable!ImageInfo();
                    }
                }
            }
            if (this._bitCount == 16)
            {
                pixelFormat = PixelFormat.Format16bppRgb555LE;
            }
            break;
        case Compression.BI_BITFIELDS:
            if (readMasks)
            {
                if (
                    fHeader.bfOffBits != BITMAPFILEHEADER.sizeof + headerSize + 4
                        * 3 + paletteSize * rgbSize)
                {
                    return Nullable!ImageInfo();
                }
                if (this._fp.rawRead(this._masks[0 .. 3]).length != 3)
                {
                    return Nullable!ImageInfo();
                }
                this._masks[3] = 0;
            }
            else if (fHeader.bfOffBits != BITMAPFILEHEADER.sizeof + headerSize
                    + paletteSize * rgbSize)
            {
                return Nullable!ImageInfo();
            }
            if (!validMask(this._masks[0]) || !validMask(this._masks[1])
                    || !validMask(this._masks[2]) || !(this._masks[3] == 0
                        || validMask(this._masks[3])))
            {
                return Nullable!ImageInfo();
            }
            if (this._masks[3] != 0)
            {
                if (this._masks == [
                    0xFF000000, 0x00FF0000, 0x0000FF00, 0x000000FF
                ])
                {
                    pixelFormat = PixelFormat.Format32bppRgbaLE;
                }
                else
                {
                    pixelFormat = PixelFormat.Format32bppArgbLE;
                    if (this._masks != [
                        0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000
                    ])
                    {
                        this._useMasks = true;
                    }
                }
            }
            if (this._bitCount == 16)
            {
                if (this._masks == [
                    0b0_11111_00000_00000, 0b0_00000_11111_00000,
                    0b0_00000_00000_11111, 0
                ])
                {
                    pixelFormat = PixelFormat.Format16bppRgb555LE;
                }
                else if (this._masks == [
                    0b11111_000000_00000, 0b00000_111111_00000,
                    0b00000_000000_11111, 0
                ])
                {
                    pixelFormat = PixelFormat.Format16bppRgb565LE;
                }
                else
                {
                    if (this._masks[0] >= 1 << 16 || this._masks[1] >= 1 << 16
                            || this._masks[2] >= 1 << 16 || this._masks[3] >= 1 << 16)
                    {
                        return Nullable!ImageInfo();
                    }
                    if (this._masks[3] == 0)
                    {
                        pixelFormat = PixelFormat.Format24bppRgbLE;
                    }
                    this._useMasks = true;
                }
            }
            else
            {
                assert(this._bitCount == 32);
                if (this._masks[3] == 0)
                {
                    pixelFormat = PixelFormat.Format24bppRgbLE;
                    if (this._masks != [0xFF0000, 0x00FF00, 0x0000FF, 0])
                    {
                        this._useMasks = true;
                    }
                }
            }
            for (int i = 0; i < paletteSize; i++)
            {
                RGBQUAD quad;
                if (this._fp.rawRead((&quad)[0 .. 1]).length != 1)
                {
                    return Nullable!ImageInfo();
                }
                if (quad.rgbReserved != 0)
                {
                    return Nullable!ImageInfo();
                }
            }
            this._palette = null;
            break;
        default:
            break;
        }
        final switch (this._bitCount)
        {
        case 1:
            pixelFormat = PixelFormat.Format1bppIndexed;
            break;
        case 2, 4:
            pixelFormat = PixelFormat.Format4bppIndexed;
            break;
        case 8:
            pixelFormat = PixelFormat.Format8bppIndexed;
            break;
        case 16:
            break;
        case 24:
            pixelFormat = PixelFormat.Format24bppRgbLE;
            break;
        case 32:
            if (this._compression != Compression.BI_BITFIELDS)
            {
                pixelFormat = PixelFormat.Format24bppRgbLE;
            }
            break;
        }
        ulong p = this._fp.tell;
        this._fp.seek(additionalOffset, SEEK_CUR);
        if (this._fp.tell - p == additionalOffset)
        {
            this._state = LoadState.End;
        }
        else
        {
            this._state = LoadState.Invalid;
        }
        this._info = ImageInfo(BmpFormat.instance(), width, height, pixelFormat);
        this._state = LoadState.BeforeImage;
        return nullable(this._info);
    }

    private bool beforeNextImage()
    {
        if (this.state == LoadState.BeforeInfo)
        {
            this.nextInfo();
            if (this.state == LoadState.Invalid)
            {
                return false;
            }
        }
        assert(this.state == LoadState.BeforeImage);
        return true;
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
        if (!this.beforeNextImage())
        {
            return null;
        }
        this._state = LoadState.Invalid;
        if (this._innerLoader !is null)
        {
            ulong p = this._fp.tell;
            Bitmap image = this._innerLoader.nextImage();
            if (this._innerLoader.state == LoadState.Invalid)
            {
                return null;
            }
            assert(image !is null);
            if (this._imageSize != 0)
            {
                ulong shift = this._fp.tell - p;
                assert(shift > 0);
                if (shift != this._imageSize)
                {
                    return null;
                }
            }
            assert(image.width == this._info.width);
            assert(image.height == this._info.height);
            assert(image.pixelFormat == this._info.pixelFormat);
            this._state = LoadState.End;
            return image;
        }
        ulong dStride;
        void[] data = pixelDataAlloc(this._info.width, this._info.height,
                this._info.pixelFormat, dStride);
        switch (this._compression)
        {
        case Compression.BI_RGB, Compression.BI_BITFIELDS:
            ubyte[] row = new ubyte[this._fStride];
            auto yRange = this._reversed ? iota(this._info.height - 1, -1,
                    -1) : iota(0, this._info.height, 1);
            if (this._bitCount == 2)
            {
                (cast(ubyte[]) data)[] = 0;
            }
            foreach (int y; yRange)
            {
                if (this._fp.rawRead(row).length != this._fStride)
                {
                    return null;
                }
                if (this._info.pixelFormat.indexed && this._palette.length < 1 << this._bitCount)
                {
                    switch (this._info.pixelFormat)
                    {
                    case PixelFormat.Format1bppIndexed:
                        if (any(row[0 .. dStride - 1]))
                        {
                            return null;
                        }
                        if (row[dStride - 1] >> (7 - this._info.width))
                        {
                            return null;
                        }
                        break;
                    case PixelFormat.Format4bppIndexed:
                        assert(this._bitCount == 4);
                        for (int x = 0; x < this._info.width; x++)
                        {
                            ubyte index;
                            if (this._bitCount == 2)
                            {
                                index = (row[x / 4] >> ((3 - x % 4) * 2)) & 0b11;
                            }
                            else
                            {
                                if (x % 2 == 0)
                                {
                                    index = row[x / 2] >> 4;
                                }
                                else
                                {
                                    index = (row[x / 2] & 0xF);
                                }
                            }
                            if (index > this._palette.length)
                            {
                                return null;
                            }
                        }
                        break;
                    case PixelFormat.Format8bppIndexed:
                        if (any!(v => v >= this._palette.length)(row[0 .. dStride]))
                        {
                            return null;
                        }
                        break;
                    default:
                        assert(0);
                    }
                }
                if (this._bitCount == 2)
                {
                    for (int x = 0; x < this._info.width; x++)
                    {
                        (cast(ubyte[]) data)[y * dStride + x / 2] |= (
                                row[x / 4] >> ((3 - x % 4) * 2) & 0b11) << ((1 - x % 2) * 4);
                    }
                }
                else if (this._useMasks)
                {
                    int shiftR = rightZeros(this._masks[0]);
                    int shiftG = rightZeros(this._masks[1]);
                    int shiftB = rightZeros(this._masks[2]);
                    int countR = rightZeros((this._masks[0] >> shiftR) + 1);
                    int countG = rightZeros((this._masks[1] >> shiftG) + 1);
                    int countB = rightZeros((this._masks[2] >> shiftB) + 1);
                    int shiftA;
                    int countA;
                    if (this._masks[3] != 0)
                    {
                        shiftA = rightZeros(this._masks[3]);
                        countA = rightZeros((this._masks[3] >> shiftA) + 1);
                    }
                    for (int x = 0; x < this._info.width; x++)
                    {
                        uint val;
                        if (this._bitCount == 32)
                        {
                            val = row[x * 4 + 3] << 24 | row[x * 4 + 2] << 16
                                | row[x * 4 + 1] << 8 | row[x * 4];
                        }
                        else
                        {
                            assert(this._bitCount == 16);
                            val = row[x * 2 + 1] << 8 | row[x * 2];
                        }
                        ubyte r = applyMask(val, shiftR, countR);
                        ubyte g = applyMask(val, shiftG, countG);
                        ubyte b = applyMask(val, shiftB, countB);
                        if (this._masks[3] == 0)
                        {
                            data[y * dStride + x * 3 .. y * dStride + (x + 1) * 3] = [
                                b, g, r
                            ];
                        }
                        else
                        {
                            ubyte a = applyMask(val, shiftB, countB);
                            assert(this._info.pixelFormat == PixelFormat.Format32bppArgbLE);
                            data[y * dStride + x * 4 .. y * dStride + (x + 1) * 4] = [
                                b, g, r, a
                            ];
                        }
                    }
                }
                else if (this._bitCount == 32 && this._masks[3] == 0)
                {
                    for (int x = 0; x < this._info.width; x++)
                    {
                        data[y * dStride + x * 3 .. y * dStride + (x + 1) * 3] = row[x * 4 .. x
                            * 4 + 3];
                    }
                }
                else
                {
                    if (this._info.pixelFormat == PixelFormat.Format16bppRgb555LE)
                    {
                        for (int i = 1; i < dStride; i += 2)
                        {
                            row[i] &= 0b01111111;
                        }
                    }
                    data[y * dStride .. (y + 1) * dStride] = row[0 .. dStride];
                }
            }
            break;
        case Compression.BI_RLE8:
            uint i = 0;
            size_t toRead = this._imageSize;
            while (i < data.length && toRead > 0)
            {
                ubyte[2] pair;
                if (this._fp.rawRead(pair).length != 2)
                {
                    return null;
                }
                toRead -= 2;
                if (pair[0] == 0)
                {
                    if (pair[1] == 0)
                    {
                        if (i % this._info.width != 0)
                        {
                            return null;
                        }
                    }
                    else if (pair[1] == 1)
                    {
                        return null;
                    }
                    else if (pair[1] == 2)
                    {
                        return null;
                    }
                    else
                    {
                        if (i + pair[1] > data.length)
                        {
                            return null;
                        }
                        if (this._fp.rawRead(data[i .. i + pair[1]]).length != pair[1])
                        {
                            return null;
                        }
                        toRead -= pair[1];
                        i += pair[1];
                        if (pair[1] % 2 != 0)
                        {
                            ubyte padding;
                            if (this._fp.rawRead((&padding)[0 .. 1]).length != 1)
                            {
                                return null;
                            }
                            toRead--;
                            if (padding != 0)
                            {
                                return null;
                            }
                        }
                    }
                }
                else
                {
                    if (i + pair[0] > data.length)
                    {
                        return null;
                    }
                    (cast(ubyte[]) data)[i .. i + pair[0]] = pair[1];
                    i += pair[0];
                }
            }
            if (toRead == 4)
            {
                ubyte[2] pair;
                if (this._fp.rawRead(pair) != [0, 0])
                {
                    return null;
                }
                toRead -= 2;
            }
            if (toRead == 2)
            {
                ubyte[2] pair;
                if (this._fp.rawRead(pair) != [0, 1])
                {
                    return null;
                }
                toRead -= 2;
            }
            if (toRead != 0)
            {
                return null;
            }
            if (this._palette.length < 256 && any!(v => v >= this._palette.length)(
                    cast(ubyte[]) data))
            {
                return null;
            }
            for (int y = 0; y < this._info.height / 2; y++)
            {
                swapRanges((cast(ubyte[]) data)[y * dStride .. (y + 1) * dStride],
                        (cast(ubyte[]) data)[(this._info.height - y - 1) * dStride .. (
                                this._info.height - y) * dStride]);
            }
            break;
        case Compression.BI_RLE4:
            int x = 0;
            int y = this._info.height - 1;
            size_t toRead = this._imageSize;
            ubyte[] row = new ubyte[dStride];
            row[] = 0;
            while (y >= 0 && toRead > 0)
            {
                ubyte[2] pair;
                if (this._fp.rawRead(pair).length != 2)
                {
                    return null;
                }
                toRead -= 2;
                if (pair[0] == 0)
                {
                    if (pair[1] == 0)
                    {
                        if (x != 0)
                        {
                            return null;
                        }
                    }
                    else if (pair[1] == 1)
                    {
                        return null;
                    }
                    else if (pair[1] == 2)
                    {
                        return null;
                    }
                    else
                    {
                        int toDraw = min(pair[1], this._info.width - x);
                        ubyte[] bytes = new ubyte[(toDraw + 1) / 2];
                        if (this._fp.rawRead(bytes).length != bytes.length)
                        {
                            return null;
                        }
                        toRead -= bytes.length;
                        if (bytes.length % 2 == 1)
                        {
                            ubyte padding;
                            if (this._fp.rawRead((&padding)[0 .. 1]).length != 1)
                            {
                                return null;
                            }
                            toRead--;
                            if (padding != 0)
                            {
                                return null;
                            }
                        }
                        if (x % 2 == 0)
                        {
                            if (pair[1] > this._info.width - x)
                            {
                                return null;
                            }
                            row[x / 2 .. (x + pair[1]) / 2] = bytes[0 .. pair[1] / 2];
                            if (pair[1] % 2 == 1)
                            {
                                row[(x + pair[1]) / 2] = bytes[pair[1] / 2] & 0xF0;
                            }
                            x += pair[1];
                        }
                        else
                        {
                            row[x / 2] |= bytes[0] >> 4;
                            x++;
                            for (int j = 0; j < (pair[1] - 1) / 2; j++)
                            {
                                row[x / 2] = cast(ubyte)(bytes[j] << 4 | bytes[j + 1] >> 4);
                                x += 2;
                            }
                            if (pair[1] % 2 == 0)
                            {
                                row[x / 2] = cast(ubyte)(bytes[pair[1] / 2 - 1] << 4);
                                x++;
                            }
                        }
                    }
                }
                else
                {
                    int toDraw = min(pair[0], this._info.width - x);
                    if (x % 2 == 0)
                    {
                        row[x / 2 .. (x + toDraw) / 2] = pair[1];
                        if (toDraw % 2 == 1)
                        {
                            row[(x + toDraw) / 2] = pair[1] & 0xF0;
                        }
                    }
                    else
                    {
                        row[x / 2] |= pair[1] >> 4;
                        row[(x + 1) / 2 .. (x + toDraw) / 2] = cast(ubyte)(pair[1] << 4
                                | pair[1] >> 4);
                        if (toDraw % 2 == 0)
                        {
                            row[(x + toDraw) / 2] = cast(ubyte)(pair[1] << 4);
                        }
                    }
                    x += toDraw;
                }
                if (x == this._info.width)
                {
                    if (this._palette.length < 16)
                    {
                        for (x = 0; x < this._info.width; x++)
                        {
                            if (x % 2 == 0)
                            {
                                if (row[x / 2] >> 4 >= this._palette.length)
                                {
                                    return null;
                                }
                            }
                            else
                            {
                                if ((row[x / 2] & 0xF) >= this._palette.length)
                                {
                                    return null;
                                }
                            }
                        }
                    }
                    data[y * dStride .. (y + 1) * dStride] = row;
                    row[] = 0;
                    y--;
                    x = 0;
                }
            }
            if (toRead == 4)
            {
                ubyte[2] pair;
                if (this._fp.rawRead(pair) != [0, 0])
                {
                    return null;
                }
                toRead -= 2;
            }
            if (toRead == 2)
            {
                ubyte[2] pair;
                if (this._fp.rawRead(pair) != [0, 1])
                {
                    return null;
                }
                toRead -= 2;
            }
            if (toRead != 0)
            {
                return null;
            }
            break;
        default:
            assert(0);
        }
        this._state = LoadState.End;
        return new Bitmap(this._info.width, this._info.height, 0, dStride,
                this._info.pixelFormat, assumeUnique(this._palette), false, data);
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
        if (!this.beforeNextImage())
        {
            return;
        }
        ulong p = this._fp.tell;
        this._fp.seek(this._imageSize, SEEK_CUR);
        if (this._fp.tell - p == this._imageSize)
        {
            this._state = LoadState.End;
        }
        else
        {
            this._state = LoadState.Invalid;
        }
    }
}

/**
 * Represents the Windows Bitmap Format for device-independent bitmaps.
 */
public final class BmpFormat : SingleImageFormat
{
    private static BmpFormat _instance = null;

    @safe private pure this() nothrow
    {
    }

    /**
     * Returns the instance of the singleton [BmpFormat] class.
     *
     * Returns: The singular instance of this class.
     */
    @safe public static BmpFormat instance() nothrow
    {
        if (_instance is null)
        {
            _instance = new BmpFormat();
        }
        return _instance;
    }

    /**
     * Checks whether a file is a file is in the Windows Bitmap Format for device-independent bitmaps, based on its first bytes.
     *
     * Params:
     *     head = The beginning of the file.
     *
     * Returns:
     *     `true` if the file is in the Windows Bitmap Format for device-independent bitmaps, `false` otherwise.
     *     If not enough bytes are provided, `false` is returned.
     */
    @nogc @safe public override bool checkFormat(const ubyte[] head) const nothrow
    {
        return head[0 .. 2] == "BM";
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
    @safe public override BmpLoader loader(File fp) const
    {
        return new BmpLoader(fp);
    }

    /**
     * Exports the given image to the given file in the Windows Bitmap Format for device-independent bitmaps.
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
        size_t fStride;
        PixelFormat format;
        if (bmp.opaque())
        {
            final switch (bmp.pixelFormat.bpp)
            {
            case 1:
                format = PixelFormat.Format1bppIndexed;
                break;
            case 4:
                format = PixelFormat.Format4bppIndexed;
                break;
            case 8:
                format = PixelFormat.Format8bppIndexed;
                break;
            case 16:
                if (bmp.pixelFormat == PixelFormat.Format16bppRgb555BE
                        || bmp.pixelFormat == PixelFormat.Format16bppRgb555LE)
                {
                    format = PixelFormat.Format16bppRgb555LE;
                }
                else
                {
                    format = PixelFormat.Format16bppRgb565LE;
                }
                break;
            case 24, 32:
                format = PixelFormat.Format24bppRgbLE;
                break;
            }
            uint paletteSize;
            if (format.indexed)
            {
                if (format == PixelFormat.Format1bppIndexed)
                {
                    paletteSize = 2;
                }
                else
                {
                    paletteSize = cast(uint) bmp.palette.length;
                }
            }
            else
            {
                paletteSize = 0;
            }
            fStride = computeStride(bmp.width, format.bpp);
            BITMAPFILEHEADER fHeader;
            fHeader.bfType = 'B' | 'M' << 8;
            fHeader.bfReserved1 = 0;
            fHeader.bfReserved2 = 0;
            BITMAPINFOHEADER biHeader;
            biHeader.biSize = BITMAPINFOHEADER.sizeof;
            biHeader.biWidth = bmp.width;
            biHeader.biHeight = bmp.height;
            biHeader.biPlanes = 1;
            biHeader.biBitCount = cast(ushort) format.bpp;
            if (format == PixelFormat.Format16bppRgb565LE)
            {
                biHeader.biCompression = Compression.BI_BITFIELDS;
                fHeader.bfSize = cast(uint)(
                        BITMAPFILEHEADER.sizeof + BITMAPINFOHEADER.sizeof + 4
                        * 3 + fStride * bmp.height);
                fHeader.bfOffBits = cast(uint)(
                        BITMAPFILEHEADER.sizeof + BITMAPINFOHEADER.sizeof + 4 * 3);
            }
            else
            {
                biHeader.biCompression = Compression.BI_RGB;
                fHeader.bfSize = cast(uint)(
                        BITMAPFILEHEADER.sizeof + BITMAPINFOHEADER.sizeof
                        + paletteSize * 4 + fStride * bmp.height);
                fHeader.bfOffBits = cast(uint)(
                        BITMAPFILEHEADER.sizeof + BITMAPINFOHEADER.sizeof + paletteSize * 4);
            }
            biHeader.biSizeImage = cast(uint)(fStride * bmp.height);
            biHeader.biXPelsPerMeter = 3780;
            biHeader.biYPelsPerMeter = 3780;
            biHeader.biClrUsed = paletteSize;
            biHeader.biClrImportant = 0;
            fHeader = leConv(fHeader);
            fp.rawWrite([fHeader]);
            biHeader = leConv(biHeader);
            fp.rawWrite([biHeader]);
            if (format == PixelFormat.Format16bppRgb565LE)
            {
                uint[3] masks = [
                    0b11111_000000_00000, 0b00000_111111_00000,
                    0b00000_000000_11111
                ];
                fp.rawWrite(masks);
            }
            if (format.indexed)
            {
                for (int i = 0; i < bmp.palette.length; i++)
                {
                    RGBQUAD quad;
                    quad.rgbRed = bmp.palette[i].r;
                    quad.rgbGreen = bmp.palette[i].g;
                    quad.rgbBlue = bmp.palette[i].b;
                    quad.rgbReserved = 0;
                    fp.rawWrite([quad]);
                }
                if (format == PixelFormat.Format1bppIndexed && bmp.palette.length == 1)
                {
                    RGBQUAD quad;
                    quad.rgbReserved = 0;
                    fp.rawWrite([quad]);
                }
            }
        }
        else
        {
            fStride = bmp.width * 4;
            BITMAPFILEHEADER fHeader;
            fHeader.bfType = 'B' | 'M' << 8;
            fHeader.bfReserved1 = 0;
            fHeader.bfReserved2 = 0;
            fHeader.bfSize = cast(uint)(
                    BITMAPFILEHEADER.sizeof + BITMAPV5HEADER.sizeof + fStride * bmp.height);
            fHeader.bfOffBits = cast(uint)(BITMAPFILEHEADER.sizeof + BITMAPV5HEADER.sizeof);
            fHeader = leConv(fHeader);
            fp.rawWrite([fHeader]);
            BITMAPV5HEADER bV5Header;
            bV5Header.bV5Size = BITMAPV5HEADER.sizeof;
            bV5Header.bV5Width = bmp.width;
            bV5Header.bV5Height = bmp.height;
            bV5Header.bV5Planes = 1;
            bV5Header.bV5BitCount = 32;
            bV5Header.bV5Compression = Compression.BI_BITFIELDS;
            bV5Header.bV5SizeImage = cast(uint)(fStride * bmp.height);
            bV5Header.bV5XPelsPerMeter = 3780;
            bV5Header.bV5YPelsPerMeter = 3780;
            bV5Header.bV5ClrUsed = 0;
            bV5Header.bV5ClrImportant = 0;
            if (bmp.pixelFormat == PixelFormat.Format32bppRgbaBE
                    || bmp.pixelFormat == PixelFormat.Format32bppRgbaLE)
            {
                format = PixelFormat.Format32bppRgbaLE;
                bV5Header.bV5RedMask = 0xFF000000;
                bV5Header.bV5GreenMask = 0x00FF0000;
                bV5Header.bV5BlueMask = 0x0000FF00;
                bV5Header.bV5AlphaMask = 0x000000FF;
            }
            else
            {
                format = PixelFormat.Format32bppArgbLE;
                bV5Header.bV5RedMask = 0x00FF0000;
                bV5Header.bV5GreenMask = 0x0000FF00;
                bV5Header.bV5BlueMask = 0x000000FF;
                bV5Header.bV5AlphaMask = 0xFF000000;
            }
            bV5Header.bV5CSType = LogicalColorSpace.LCS_CALIBRATED_RGB;
            bV5Header.bV5Endpoints = CIEXYZTRIPLE(CIEXYZ(toFxpt2dot30(0.6400), toFxpt2dot30(0.3300),
                    toFxpt2dot30(0.0300)), CIEXYZ(toFxpt2dot30(0.3000), toFxpt2dot30(0.6000), toFxpt2dot30(0.1000)),
                    CIEXYZ(toFxpt2dot30(0.1500), toFxpt2dot30(0.0600), toFxpt2dot30(0.7900)));
            bV5Header.bV5GammaRed = 0x00023333;
            bV5Header.bV5GammaGreen = 0x00023333;
            bV5Header.bV5GammaBlue = 0x00023333;
            bV5Header.bV5Intent = GamutMappingIntent.LCS_GM_ABS_COLORIMETRIC;
            bV5Header.bV5ProfileData = 0;
            bV5Header.bV5ProfileSize = 0;
            bV5Header.bV5Reserved = 0;
            bV5Header = leConv(bV5Header);
            fp.rawWrite([bV5Header]);
        }
        ubyte[] row = new ubyte[fStride];
        ulong rowDataSize;
        getPixelDataSize(bmp.width, bmp.height, format, rowDataSize);
        row[rowDataSize .. $] = 0;
        foreach (int y; bmp.yBottomUp)
        {
            bmp.rawLine(y, row.ptr, 0, format, format.indexed ? bmp.palette : null);
            if (format == PixelFormat.Format16bppRgb555)
            {
                for (size_t i = 1; i < rowDataSize; i += 2)
                {
                    row[i] &= 0b01111111;
                }
            }
            fp.rawWrite(row);
        }
    }
}

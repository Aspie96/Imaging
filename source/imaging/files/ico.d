/**
 * This module provides a codec for the Icon Format.
 *
 * See_Also:
 *     [ICO Format Overview](https://learn.microsoft.com/windows/win32/wic/ico-format-overview),
 *     [Icons](https://learn.microsoft.com/previous-versions/ms997538(v=msdn.10)),
 *     [The evolution of the ICO file format, part 1: Monochrome beginnings](https://devblogs.microsoft.com/oldnewthing/20101018-00/?p=12513),
 *     [The evolution of the ICO file format, part 2: Now in color!](https://devblogs.microsoft.com/oldnewthing/20101019-00/?p=12503),
 *     [The evolution of the ICO file format, part 3: Alpha-blended images](https://devblogs.microsoft.com/oldnewthing/20101021-00/?p=12483),
 *     [The evolution of the ICO file format, part 4: PNG images](https://devblogs.microsoft.com/oldnewthing/20101022-00/?p=12473),
 *     [The format of icon resources](https://devblogs.microsoft.com/oldnewthing/20120720-00/?p=7083),
 *     [The format of icon resources, revisited](https://devblogs.microsoft.com/oldnewthing/20231025-00/?p=108925)
 *
 * Copyright: Copyright (C) 2026 Valentino Giudice
 * License: BSL-1.0
 * Authors: [Valentino Giudice](https://www.functorfault.net/)
 */
module imaging.files.ico;

import imaging : Bitmap, bpp, Color, indexed, pixelDataAlloc, PixelFormat;
import imaging.files : ImageFormat, ImageInfo, ImageLoader, leConv, LoadState, MultiImageFormat;
import imaging.files.png : pngSignature;
import std.algorithm.comparison : among;
import std.algorithm.iteration : filter;
import std.algorithm.searching : all, any, countUntil;
import std.algorithm.sorting : sort;
import std.array : array, assocArray;
import std.exception : assumeUnique, enforce;
import std.range : iota;
import std.stdio : File, SEEK_CUR;
import std.typecons : Nullable, nullable;

version (Windows)
{
    import core.sys.windows.wingdi : BITMAPINFOHEADER, RGBQUAD;
}
else
{
    import imaging.files.bmp : BITMAPINFOHEADER, RGBQUAD;
}

private struct ICONDIRHEADER
{
    ushort idReserved;
    ushort idType;
    ushort idCount;
}

private struct ICONDIRENTRY
{
    ubyte bWidth;
    ubyte bHeight;
    ubyte bColorCount;
    ubyte bReserved;
    ushort wPlanes;
    ushort wBitCount;
    uint dwBytesInRes;
    uint dwImageOffset;

    bool valid()
    {
        if (this.bReserved != 0)
        {
            return false;
        }
        if (this.wPlanes != 1)
        {
            return false;
        }
        if (!among!(0, 1, 2, 4, 8, 16, 24, 32)(this.wBitCount))
        {
            return false;
        }
        int paletteSize = (0 < this.wBitCount && this.wBitCount <= 8) ? (1 << this.wBitCount) : 0;
        if (this.bColorCount != 0 && this.bColorCount != paletteSize)
        {
            return false;
        }
        return true;
    }
}

private struct CURSORDIRENTRY
{
    ubyte bWidth;
    ubyte bHeight;
    ubyte bColorCount;
    ubyte bReserved;
    ushort xHotspot;
    ushort yHotspot;
    uint dwBytesInRes;
    uint dwImageOffset;

    bool valid()
    {
        if (this.bReserved != 0)
        {
            return false;
        }
        int width = this.bWidth > 0 ? this.bWidth : 256;
        int height = this.bHeight > 0 ? this.bHeight : 256;
        if (this.xHotspot > width)
        {
            return false;
        }
        if (this.yHotspot > height)
        {
            return false;
        }
        if (!among!(0, 2, 16)(this.bColorCount))
        {
            return false;
        }
        return true;
    }
}

private size_t bitShift(int bpp, size_t x)
{
    return 8 - (1 + (x % (8 / bpp))) * bpp;
}

private size_t computeStride(int width, int bpp)
{
    return ((width * bpp + 31) & ~31) >> 3;
}

/**
 * Represents an image loader for a file in the Icon Format or the Cursor Format.
 */
public final class IcoLoader : ImageLoader
{
    private File _fp;
    private LoadState _state;
    private bool _isCursor;
    private ICONDIRENTRY[] _iconEntries;
    private CURSORDIRENTRY[] _curEntries;
    private ushort _length;
    private ushort _index;
    private uint _offset;
    private Bitmap _bmp;

    /**
     * Creates an image loader for a file in the Icon Format or the Cursor Format.
     * Calling this constructor performs read operations and advances the file pointer.
     *
     * Params:
     *     fp =
     *         The file pointer to be used.
     *         It must be open for binary read.
     */
    public this(File fp)
    {
        this._fp = fp;
        this._state = LoadState.Invalid;
        ICONDIRHEADER idHeader;
        if (fp.rawRead((&idHeader)[0 .. 1]).length != 1)
        {
            return;
        }
        idHeader = leConv(idHeader);
        if (idHeader.idReserved != 0)
        {
            return;
        }
        if (idHeader.idType != 1 && idHeader.idType != 2)
        {
            return;
        }
        if (idHeader.idCount == 0)
        {
            return;
        }
        this._isCursor = idHeader.idType == 2;
        this._length = idHeader.idCount;
        if (this._isCursor)
        {
            this._curEntries = new CURSORDIRENTRY[this._length];
            if (fp.rawRead(this._curEntries).length != this._length)
            {
                return;
            }
            for (int i = 0; i < this._curEntries.length; i++)
            {
                this._curEntries[i] = leConv(this._curEntries[i]);
                if (!this._curEntries[i].valid)
                {
                    return;
                }
            }
        }
        else
        {
            this._iconEntries = new ICONDIRENTRY[this._length];
            if (fp.rawRead(this._iconEntries).length != this._length)
            {
                return;
            }
            for (int i = 0; i < this._iconEntries.length; i++)
            {
                this._iconEntries[i] = leConv(this._iconEntries[i]);
                if (!this._iconEntries[i].valid)
                {
                    return;
                }
            }
        }
        this._index = 0;
        this._offset = cast(uint)(ICONDIRHEADER.sizeof + ICONDIRENTRY.sizeof * this._length);
        this._state = LoadState.BeforeInfo;
    }

    /// The instance of the [IcoFormat] singleton class.
    @property public IcoFormat format() const nothrow
    {
        return IcoFormat.instance();
    }

    /// The current state of the loader.
    @nogc @property @safe public pure LoadState state() const nothrow
    {
        return this._state;
    }

    /// The total amount of images in the file.
    @nogc @property @safe public int length() const nothrow
    in (this.state != LoadState.Invalid)
    {
        return this._length;
    }

    private static int maxIndex(int width, int height, size_t dStride, int bpp, ubyte[] data)
    {
        int maxI = 0;
        int limit = (1 << bpp) - 1;
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                ubyte val = data[dStride * y + (x * bpp) / 8];
                val >>= bitShift(bpp, x);
                val &= 0xFF >> (8 - bpp);
                if (val == limit)
                {
                    return limit;
                }
                if (val > maxI)
                {
                    maxI = val;
                }
            }
        }
        return maxI;
    }

    /**
     * Tries to read information about the next image in the file.
     * The [state] property must be equal to either [LoadState.BeforeInfo] or [LoadState.BeforeImage].
     * The function sets it to a value representing the new state of the loader.
     *
     * Returns:
     *     An [ImageInfo] instance if data is read correctly from the file.
     *     In this case the [state] property is set to [LoadState.BeforeImage].
     *     A null value if invalid data is encountered or the file contains no more images.
     *     In this case the [state] property is set to either [LoadState.Invalid] or [LoadState.End].
     */
    public Nullable!ImageInfo nextInfo()
    in (this.state == LoadState.BeforeInfo || this.state == LoadState.BeforeImage)
    {
        this._state = LoadState.Invalid;
        this._bmp = null;
        uint dwImageOffset;
        ubyte bWidth;
        ubyte bHeight;
        uint dwBytesInRes;
        ushort wBitCount;
        ubyte bColorCount;
        if (this._isCursor)
        {
            CURSORDIRENTRY entry = this._curEntries[this._index];
            dwImageOffset = entry.dwImageOffset;
            bWidth = entry.bWidth;
            bHeight = entry.bHeight;
            dwBytesInRes = entry.dwBytesInRes;
            wBitCount = 0;
            bColorCount = entry.bColorCount;
        }
        else
        {
            ICONDIRENTRY entry = this._iconEntries[this._index];
            dwImageOffset = entry.dwImageOffset;
            bWidth = entry.bWidth;
            bHeight = entry.bHeight;
            dwBytesInRes = entry.dwBytesInRes;
            wBitCount = entry.wBitCount;
            bColorCount = entry.bColorCount;
        }
        if (dwImageOffset < this._offset)
        {
            return Nullable!ImageInfo();
        }
        uint offset = dwImageOffset - this._offset;
        ulong p = this._fp.tell;
        this._fp.seek(offset, SEEK_CUR);
        if (this._fp.tell - p != offset)
        {
            return Nullable!ImageInfo();
        }
        int width = bWidth > 0 ? bWidth : 256;
        int height = bHeight > 0 ? bHeight : 256;
        ubyte[8] head;
        if (this._fp.rawRead(head[]).length != 8)
        {
            return Nullable!ImageInfo();
        }
        this._fp.seek(-8, SEEK_CUR);
        if (head == pngSignature)
        {
            if (wBitCount != 0 && wBitCount != 32)
            {
                return Nullable!ImageInfo();
            }
            ImageLoader loader = ImageFormat.png.loader(this._fp);
            p = this._fp.tell;
            Nullable!ImageInfo pngInfo = loader.nextInfo();
            if (loader.state == LoadState.Invalid)
            {
                return Nullable!ImageInfo();
            }
            assert(!pngInfo.isNull);
            if (pngInfo.get.width != width || pngInfo.get.height != height)
            {
                return Nullable!ImageInfo();
            }
            this._bmp = loader.nextImage();
            if (loader.state == LoadState.Invalid)
            {
                return Nullable!ImageInfo();
            }
            assert(this._bmp !is null);
            ulong shift = this._fp.tell - p;
            assert(shift > 0);
            if (dwBytesInRes != 0 && shift != dwBytesInRes)
            {
                return Nullable!ImageInfo();
            }
            this._offset += shift;
            this._state = LoadState.BeforeImage;
            ImageInfo info = ImageInfo(IcoFormat.instance(), width, height,
                    pngInfo.get.pixelFormat);
            return nullable(info);
        }
        if (!this._isCursor && wBitCount == 0)
        {
            return Nullable!ImageInfo();
        }
        BITMAPINFOHEADER icHeader;
        if (this._fp.rawRead((&icHeader)[0 .. 1]).length != 1)
        {
            return Nullable!ImageInfo();
        }
        icHeader = leConv(icHeader);
        this._offset += BITMAPINFOHEADER.sizeof;
        if (icHeader.biSize != BITMAPINFOHEADER.sizeof)
        {
            return Nullable!ImageInfo();
        }
        if (icHeader.biWidth != width)
        {
            return Nullable!ImageInfo();
        }
        if (icHeader.biHeight != height * 2)
        {
            return Nullable!ImageInfo();
        }
        if (icHeader.biPlanes != 1)
        {
            return Nullable!ImageInfo();
        }
        if (!among!(1, 2, 4, 8, 16, 24, 32)(icHeader.biBitCount))
        {
            return Nullable!ImageInfo();
        }
        if (!this._isCursor && icHeader.biBitCount != wBitCount)
        {
            return Nullable!ImageInfo();
        }
        int paletteSize = icHeader.biBitCount <= 8 ? (1 << icHeader.biBitCount) : 0;
        size_t fStride1 = computeStride(width, icHeader.biBitCount);
        size_t fStride2 = computeStride(width, 1);
        if (dwBytesInRes != (BITMAPINFOHEADER.sizeof + RGBQUAD.sizeof * paletteSize + (
                fStride1 + fStride2) * height))
        {
            return Nullable!ImageInfo();
        }
        if (icHeader.biCompression != 0 && !(icHeader.biCompression == 3 && icHeader.biBitCount
                == 16))
        {
            return Nullable!ImageInfo();
        }
        if (icHeader.biSizeImage != 0 && icHeader.biSizeImage != (fStride1 + fStride2) * height
                && icHeader.biSizeImage != fStride1 * height)
        {
            return Nullable!ImageInfo();
        }
        if (icHeader.biClrUsed != 0 && icHeader.biClrUsed != paletteSize)
        {
            return Nullable!ImageInfo();
        }
        if (icHeader.biClrImportant > paletteSize)
        {
            return Nullable!ImageInfo();
        }
        bool format565 = false;
        if (icHeader.biCompression == 3)
        {
            ubyte[3] masks;
            if (this._fp.rawRead(masks[]).length != 3)
            {
                return Nullable!ImageInfo();
            }
            this._offset += 3;
            if (masks == [
                0b11111_000000_00000, 0b00000_111111_00000, 0b00000_000000_11111
            ])
            {
                format565 = true;
            }
            else if (masks != [
                0b0_11111_00000_00000, 0b0_00000_11111_00000,
                0b0_00000_00000_11111
            ])
            {
                return Nullable!ImageInfo();
            }
        }
        RGBQUAD[] icColors;
        if (paletteSize != 0)
        {
            icColors = new RGBQUAD[paletteSize];
            if (this._fp.rawRead(icColors).length != paletteSize)
            {
                return Nullable!ImageInfo();
            }
        }
        this._offset += RGBQUAD.sizeof * paletteSize;
        ubyte[] icXOR = new ubyte[fStride1 * height];
        if (this._fp.rawRead(icXOR).length != icXOR.length)
        {
            return Nullable!ImageInfo();
        }
        this._offset += icXOR.length;
        ubyte[] icAND = new ubyte[fStride2 * height];
        if (this._fp.rawRead(icAND).length != icAND.length)
        {
            return Nullable!ImageInfo();
        }
        this._offset += icAND.length;
        Color[] palette;
        if (paletteSize == 0)
        {
            palette = null;
        }
        else
        {
            int maxI = maxIndex(width, height, fStride1, icHeader.biBitCount, icXOR);
            palette = new Color[maxI + 1];
            for (int i = 0; i < palette.length; i++)
            {
                if (icColors[i].rgbReserved != 0)
                {
                    return Nullable!ImageInfo();
                }
                palette[i] = Color(icColors[i].rgbRed, icColors[i].rgbGreen, icColors[i].rgbBlue);
            }
        }
        if (fStride2 * 8 != width)
        {
            int bitPadding = width % 8;
            for (int y = 0; y < height; y++)
            {
                icAND[y * fStride2 + width / 8 + 1 .. (y + 1) * fStride2] = 0;
                if (bitPadding != 0)
                {
                    icAND[y * fStride2 + width / 8] &= 0xFF << (8 - bitPadding);
                }
            }
        }
        bool allAndZero = all!(v => v == 0)(icAND);
        void[] data;
        PixelFormat pixelFormat;
        if (allAndZero || icHeader.biBitCount == 32)
        {
            data = null;
            final switch (icHeader.biBitCount)
            {
            case 1:
                pixelFormat = PixelFormat.Format1bppIndexed;
                break;
            case 2:
                pixelFormat = PixelFormat.Format4bppIndexed;
                size_t dStride = (width * 4 + 4) / 8;
                data = new ubyte[dStride * height];
                for (int y = 0; y < width; y++)
                {
                    for (int x = 0; x < width; x++)
                    {
                        ubyte val = icXOR[y * fStride1 + x / 4];
                        val >>= (3 - x % 4) * 2;
                        val &= 0xFF >> 6;
                        (cast(ubyte[]) data)[dStride * y + x / 2] |= val << (1 - x % 2) * 4 & 0xF;
                    }
                }
                break;
            case 4:
                pixelFormat = PixelFormat.Format4bppIndexed;
                break;
            case 8:
                pixelFormat = PixelFormat.Format8bppIndexed;
                break;
            case 16:
                if (format565)
                {
                    pixelFormat = PixelFormat.Format16bppRgb565LE;
                }
                else
                {
                    pixelFormat = PixelFormat.Format16bppRgb555LE;
                }
                break;
            case 24:
                pixelFormat = PixelFormat.Format24bppRgbLE;
                break;
            case 32:
                bool allXorOpaque = all!(i => icXOR[i * 4 + 3] == 0)(iota(width * height));
                allXorOpaque |= all!(i => icXOR[i * 4 + 3] == 255)(iota(width * height));
                if (allXorOpaque)
                {
                    if (allAndZero)
                    {
                        pixelFormat = PixelFormat.Format24bppRgbLE;
                        data = new ubyte[width * height * 3];
                        for (int y = 0; y < height; y++)
                        {
                            for (int x = 0; x < width; x++)
                            {
                                ubyte[4] bgrx = icXOR[fStride1 * y + x * 4 .. fStride1 * y + (
                                            x + 1) * 4];
                                (cast(ubyte[3][])(data))[width * y + x] = bgrx[0 .. 3];
                            }
                        }
                    }
                    else
                    {
                        pixelFormat = PixelFormat.Format32bppArgbLE;
                        data = new uint[width * height];
                        for (int y = 0; y < height; y++)
                        {
                            for (int x = 0; x < width; x++)
                            {
                                ubyte[4] bgra = icXOR[fStride1 * y + x * 4 .. fStride1 * y + (
                                            x + 1) * 4];
                                bool transparent = icAND[fStride2 * y + x / 8] >> (7 - x % 8) & 1;
                                bgra[3] = transparent ? 0 : 255;
                                (cast(ubyte[4][])(data))[width * y + x] = bgra;
                            }
                        }
                    }
                }
                else
                {
                    pixelFormat = PixelFormat.Format32bppArgbLE;
                }
                break;
            }
        }
        else if (icHeader.biBitCount <= 8)
        {
            bool[] allOpaque = new bool[palette.length];
            allOpaque[] = true;
            bool[] allTransparent = new bool[palette.length];
            allTransparent[] = true;
            for (int y = 0; y < height; y++)
            {
                for (int x = 0; x < width; x++)
                {
                    ubyte index = icXOR[fStride1 * y + x * icHeader.biBitCount / 8];
                    index >>= bitShift(icHeader.biBitCount, x);
                    index &= 0xFF >> (8 - icHeader.biBitCount);
                    bool transparent = icAND[fStride2 * y + x / 8] >> (7 - x % 8) & 1;
                    if (transparent)
                    {
                        allOpaque[index] = false;
                    }
                    else
                    {
                        allTransparent[index] = false;
                    }
                }
            }
            for (int i = 0; i < palette.length; i++)
            {
                if (allTransparent[i])
                {
                    palette[i].a = 0;
                }
            }
            bool createData;
            size_t transparentIndex;
            if (all!(i => allOpaque[i] || allTransparent[i])(iota(palette.length)))
            {
                createData = false;
                final switch (icHeader.biBitCount)
                {
                case 1:
                    pixelFormat = pixelFormat.Format1bppIndexed;
                    break;
                case 2:
                    pixelFormat = pixelFormat.Format4bppIndexed;
                    createData = true;
                    break;
                case 4:
                    pixelFormat = pixelFormat.Format4bppIndexed;
                    break;
                case 8:
                    pixelFormat = pixelFormat.Format8bppIndexed;
                    break;
                }
            }
            else
            {
                createData = true;
                transparentIndex = countUntil(allTransparent, true);
                if (transparentIndex == -1)
                {
                    if (palette.length <= 255)
                    {
                        transparentIndex = palette.length;
                        palette ~= [Color(0, 0, 0, 0)];
                    }
                    else
                    {
                        pixelFormat = PixelFormat.Format32bppArgbLE;
                        data = new uint[width * height];
                        palette = null;
                        for (int y = 0; y < height; y++)
                        {
                            for (int x = 0; x < width; x++)
                            {
                                ubyte index = icXOR[fStride1 * y + x * icHeader.biBitCount / 8];
                                index >>= bitShift(icHeader.biBitCount, x);
                                index &= 0xFF >> (8 - icHeader.biBitCount);
                                bool transparent = icAND[fStride2 * y + x / 8] >> (7 - x % 8) & 1;
                                Color color = palette[index];
                                if (transparent)
                                {
                                    color.a = 0;
                                }
                                (cast(ubyte[4][]) data)[width * y + x] = [
                                    color.b, color.g, color.r, color.a
                                ];
                            }
                        }
                    }
                }
                if (palette.length > 0)
                {
                    if (palette.length <= 2)
                    {
                        pixelFormat = PixelFormat.Format1bppIndexed;
                    }
                    else if (palette.length <= 16)
                    {
                        pixelFormat = PixelFormat.Format4bppIndexed;
                    }
                    else
                    {
                        pixelFormat = PixelFormat.Format8bppIndexed;
                    }
                }
            }
            if (createData)
            {
                assert(transparentIndex != -1);
                size_t dStride;
                data = pixelDataAlloc(width, height, pixelFormat, dStride);
                for (int y = 0; y < height; y++)
                {
                    for (int x = 0; x < width; x++)
                    {
                        ubyte index = icXOR[fStride1 * y + x * icHeader.biBitCount / 8];
                        index >>= bitShift(icHeader.biBitCount, x);
                        index &= 0xFF >> (8 - icHeader.biBitCount);
                        bool transparent = icAND[fStride2 * y + x / 8] >> (7 - x % 8) & 1;
                        if (transparent && !allTransparent[index])
                        {
                            index = cast(ubyte) transparentIndex;
                        }
                        (cast(ubyte[]) data)[dStride * y + x * pixelFormat.bpp / 8] |= index << bitShift(
                                pixelFormat.bpp, x);
                    }
                }
            }
        }
        else if (bColorCount == 16)
        {
            pixelFormat = PixelFormat.Format32bppArgbLE;
            data = new uint[width * height];
            for (int y = 0; y < height; y++)
            {
                for (int x = 0; x < width; x++)
                {
                    bool transparent = icAND[fStride2 * y + x / 8] >> (7 - x % 8) & 1;
                    ushort val = icXOR[fStride1 * y + x * 2 + 1] << 8 | icXOR[fStride1 * y + x * 2];
                    ubyte r;
                    ubyte g;
                    ubyte b;
                    if (format565)
                    {
                        r = val >> 11 & 0b11111;
                        r = cast(ubyte)(r << 3 | r >> 3);
                        g = val >> 5 & 0b111111;
                        g = cast(ubyte)(g << 2 | g >> 4);
                        b = val & 0b11111;
                        b = cast(ubyte)(b << 3 | b >> 2);
                    }
                    else
                    {
                        r = val >> 10 & 0b11111;
                        r = cast(ubyte)(r << 3 | r >> 2);
                        g = val >> 5 & 0b11111;
                        g = cast(ubyte)(g << 3 | g >> 2);
                        b = val & 0b11111;
                        b = cast(ubyte)(b << 3 | b >> 2);
                    }
                    (cast(ubyte[4][]) data)[width * y + x] = [
                        b, g, r, transparent ? 0 : 255
                    ];
                }
            }
        }
        else
        {
            assert(icHeader.biBitCount == 24);
            pixelFormat = PixelFormat.Format32bppArgbLE;
            data = new uint[width * height];
            for (int y = 0; y < height; y++)
            {
                for (int x = 0; x < width; x++)
                {
                    bool transparent = icAND[fStride2 * y + x / 8] >> (7 - x % 8) & 1;
                    ubyte[3] bgr = icXOR[fStride1 * y + x * 3 .. fStride1 * y + (x + 1) * 3];
                    (cast(ubyte[4][]) data)[width * y + x] = [
                        bgr[0], bgr[1], bgr[2], transparent ? 0 : 255
                    ];
                }
            }
        }
        size_t dStride = (width * pixelFormat.bpp + 7) / 8;
        if (data == null)
        {
            if (pixelFormat.bpp <= 8 && icXOR.length == dStride * height)
            {
                data = icXOR;
            }
            else
            {
                if (pixelFormat.bpp == 16)
                {
                    data = new ushort[width * height];
                }
                else if (pixelFormat.bpp == 32)
                {
                    data = new uint[width * height];
                }
                else
                {
                    data = new ubyte[dStride * height];
                }
                for (int y = 0; y < height; y++)
                {
                    data[dStride * y .. dStride * (y + 1)] = icXOR[fStride1
                        * y .. fStride1 * y + dStride];
                }
            }
            if (pixelFormat == PixelFormat.Format16bppRgb555LE)
            {
                for (size_t i = 1; i < data.length; i += 2)
                {
                    (cast(ubyte[]) data)[i] &= 0b01111111;
                }
            }
            else
            {
                int bitPadding = (width * pixelFormat.bpp) % 8;
                if (bitPadding != 0)
                {
                    for (int y = 0; y < height; y++)
                    {
                        (cast(ubyte[]) data)[dStride * (y + 1) - 1] &= 0xFF << (8 - bitPadding);
                    }
                }
            }
        }
        this._bmp = new Bitmap(width, height, 0, dStride, pixelFormat,
                assumeUnique(palette), false, data);
        if (!this._bmp.valid())
        {
            return Nullable!ImageInfo();
        }
        this._bmp.flipVer();
        this._state = LoadState.BeforeImage;
        ImageInfo info = ImageInfo(IcoFormat.instance(), width, height, pixelFormat);
        return nullable(info);
    }

    /**
     * Tries to read the next image in the file.
     * The [state] property must be equal to either [LoadState.BeforeInfo] or [LoadState.BeforeImage].
     * The function sets it to a value representing the new state of the loader.
     *
     * Returns:
     *     A [Bitmap] instance if data is read correctly from the file.
     *     In this case the [state] property is set to either [LoadState.BeforeInfo] or [LoadState.End].
     *     A null value if invalid data is encountered.
     *     In this case the [state] property is set to [LoadState.Invalid].
     */
    public Bitmap nextImage()
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
        this._index++;
        if (this._index == this.length)
        {
            this._state = LoadState.End;
        }
        else
        {
            this._state = LoadState.BeforeInfo;
        }
        return this._bmp;
    }

    /**
     * Skips the next image in the file.
     * The [state] property must be equal to either [LoadState.BeforeInfo] or [LoadState.BeforeImage].
     * The function sets it to a value representing the new state of the loader.
     */
    public void skipImage()
    in (this.state == LoadState.BeforeImage || this.state == LoadState.BeforeInfo)
    {
        this._index++;
    }
}

/**
 * Represents the Icon Format.
 */
public final class IcoFormat : MultiImageFormat
{
    private static IcoFormat _instance = null;

    @safe private pure this() nothrow
    {
    }

    /**
     * Returns the instance of the singleton class [IcoFormat].
     *
     * Returns: The singular instance of this class.
     */
    @safe public static IcoFormat instance() nothrow
    {
        if (_instance is null)
        {
            _instance = new IcoFormat();
        }
        return _instance;
    }

    /**
     * Checks whether a file is is either the Icon Format or the Cursor Format, based on its first bytes.
     *
     * Params:
     *     head = The beginning of the file.
     *
     * Returns:
     *     `true` if the file is in the Icon Format or the Cursor Format, `false` otherwise.
     *     If not enough bytes are provided, `false` is returned.
     */
    public override bool checkFormat(const ubyte[] head) const
    {
        ubyte[4] bytes = head[0 .. 4];
        return bytes == [0, 0, 1, 0] || bytes == [0, 0, 2, 0];
    }

    /**
     * Creates a loader for the given file.
     * The loader, upon creation, reads information about the whole file, learning the number of images it contains.
     *
     * Prams:
     *     fp =
     *         The file pointer to be used.
     *         It must be open for binary read.
     *         It must refer to a file in this format and point to its beginning.
     *         The animation file may be part of a larger file.
     *         Any data preceding to the file pointer is ignored.
     *
     * Returns: The created loader.
     */
    public override IcoLoader loader(File fp) const
    {
        return new IcoLoader(fp);
    }

    /**
     * Exports the given images to the given file.
     * After the operation, the given file pointer is set to the end of the written data (also the end of the file).
     *
     * Params:
     *     fp =
     *         The file pointer to be used.
     *         It must be open for binary write.
     *         Any data preceding the file pointer is left untouched.
     *     bitmaps =
     *         The images to be saved.
     *         The array must contain at least one image and cannot contain null values.
     *         The width and height of each image must be no larger than 256.
     */
    public override void save(File fp, const Bitmap[] bitmaps) const
    in
    {
        assert(bitmaps != null);
        assert(bitmaps.length > 0);
        assert(all!(bmp => bmp !is null)(bitmaps));
    }
    do
    {
        enforce(all!(bmp => bmp.width <= 256 && bmp.height <= 256)(bitmaps));
        ICONDIRHEADER idHeader;
        idHeader.idReserved = 0;
        idHeader.idType = 1;
        idHeader.idCount = cast(ushort) bitmaps.length;
        idHeader = leConv(idHeader);
        fp.rawWrite([idHeader]);
        ICONDIRENTRY[] idEntries = new ICONDIRENTRY[bitmaps.length];
        bool[] opaque = new bool[bitmaps.length];
        bool[] middleOpacity = new bool[bitmaps.length];
        Color[][] palettes = new Color[][bitmaps.length];
        for (int i = 0; i < bitmaps.length; i++)
        {
            enforce(bitmaps[i].valid());
            idEntries[i].bWidth = cast(ubyte) bitmaps[i].width;
            idEntries[i].bHeight = cast(ubyte) bitmaps[i].height;
            opaque[i] = bitmaps[i].opaque();
            middleOpacity[i] = false;
            if (!opaque[i])
            {
                middleOpacity[i] = any!(y => any!(c => c.a != 0 && c.a != 255)(
                        bitmaps[i].scanLine(y)))(iota(bitmaps[i].height));
            }
            int paletteSize;
            ushort bpp;
            palettes[i] = null;
            if (bitmaps[i].pixelFormat == PixelFormat.Format16bppRgb555LE
                    || bitmaps[i].pixelFormat == PixelFormat.Format16bppRgb555BE)
            {
                paletteSize = 0;
                bpp = 16;
            }
            else if (middleOpacity[i])
            {
                paletteSize = 0;
                bpp = 32;
            }
            else
            {
                size_t[Color] counts = bitmaps[i].counts;
                Color[] colors = array(filter!(a => a.a != 0)(counts.byKey));
                sort!((a, b) => counts[a] > counts[b])(colors);
                if (colors.length <= 256)
                {
                    bool newPalette = false;
                    if (!bitmaps[i].indexed || colors.length < bitmaps[i].palette.length)
                    {
                        if (colors.length <= 1 << 1 && (!bitmaps[i].indexed
                                || bitmaps[i].palette.length > 1 << 1))
                        {
                            paletteSize = 1 << 1;
                            bpp = 1;
                            newPalette = true;
                        }
                        else if (colors.length <= 1 << 4 && (!bitmaps[i].indexed
                                || bitmaps[i].palette.length > 1 << 4))
                        {
                            paletteSize = 1 << 4;
                            bpp = 4;
                            newPalette = true;
                        }
                        else if (colors.length <= 1 << 8 && !bitmaps[i].indexed)
                        {
                            paletteSize = 1 << 8;
                            bpp = 8;
                            newPalette = true;
                        }
                    }
                    if (newPalette)
                    {
                        palettes[i] = colors;
                    }
                    else if (bitmaps[i].indexed)
                    {
                        paletteSize = 1 << bitmaps[i].bpp;
                        bpp = cast(ushort) bitmaps[i].bpp;
                    }
                    else
                    {
                        paletteSize = 0;
                        bpp = 32;
                    }
                }
                else
                {
                    paletteSize = 0;
                    bpp = 32;
                }
            }
            idEntries[i].bColorCount = cast(ubyte) paletteSize;
            idEntries[i].bReserved = 0;
            idEntries[i].wPlanes = 1;
            idEntries[i].wBitCount = bpp;
            size_t fStride1 = computeStride(bitmaps[i].width, bpp);
            size_t fStride2 = computeStride(bitmaps[i].width, 1);
            idEntries[i].dwBytesInRes = cast(uint)(BITMAPINFOHEADER.sizeof + RGBQUAD.sizeof * paletteSize + (
                    fStride1 + fStride2) * bitmaps[i].height);
            if (i == 0)
            {
                idEntries[0].dwImageOffset = cast(uint)(
                        ICONDIRHEADER.sizeof + ICONDIRENTRY.sizeof * bitmaps.length);
            }
            else
            {
                idEntries[i].dwImageOffset = idEntries[i - 1].dwImageOffset
                    + idEntries[i - 1].dwBytesInRes;
            }
            assert(idEntries[i].valid);
            idEntries[i] = leConv(idEntries[i]);
        }
        fp.rawWrite(idEntries);
        for (int i = 0; i < bitmaps.length; i++)
        {
            BITMAPINFOHEADER icHeader;
            icHeader.biSize = BITMAPINFOHEADER.sizeof;
            icHeader.biWidth = bitmaps[i].width;
            icHeader.biHeight = bitmaps[i].height * 2;
            icHeader.biPlanes = 1;
            ushort bpp;
            if (palettes[i] != null)
            {
                if (palettes[i].length <= 1 << 1)
                {
                    bpp = 1;
                }
                else if (palettes[i].length <= 1 << 4)
                {
                    bpp = 4;
                }
                else
                {
                    bpp = 8;
                }
            }
            else if (bitmaps[i].indexed && !middleOpacity[i])
            {
                bpp = cast(ushort) bitmaps[i].bpp;
            }
            else if (bitmaps[i].pixelFormat == PixelFormat.Format16bppRgb555LE
                    || bitmaps[i].pixelFormat == PixelFormat.Format16bppRgb555BE)
            {
                bpp = 16;
            }
            else
            {
                bpp = 32;
            }
            icHeader.biBitCount = bpp;
            size_t fStride1 = computeStride(bitmaps[i].width, bpp);
            size_t fStride2 = computeStride(bitmaps[i].width, 1);
            icHeader.biSizeImage = cast(uint)((fStride1 + fStride2) * bitmaps[i].height);
            icHeader = leConv(icHeader);
            fp.rawWrite([icHeader]);
            bool toWrite;
            PixelFormat pixelFormat = bitmaps[i].pixelFormat;
            if (palettes[i] != null)
            {
                RGBQUAD[] icColors = new RGBQUAD[1 << bpp];
                for (int j = 0; j < palettes[i].length; j++)
                {
                    icColors[j].rgbRed = palettes[i][j].r;
                    icColors[j].rgbGreen = palettes[i][j].g;
                    icColors[j].rgbBlue = palettes[i][j].b;
                    icColors[j].rgbReserved = 0;
                }
                icColors[palettes[i].length .. $] = RGBQUAD(0, 0, 0, 0);
                fp.rawWrite(icColors);
                int[Color] toIndex = assocArray(palettes[i], iota(cast(int) palettes[i].length));
                ubyte[] data = new ubyte[fStride1 * bitmaps[i].height];
                data[] = 0;
                int dIndex = 0;
                foreach (int y; bitmaps[i].yBottomUp)
                {
                    foreach (int x, Color color; bitmaps[i].scanLine(y))
                    {
                        if (color.a == 255)
                        {
                            int cIndex = toIndex[color];
                            if (palettes[i].length <= 1 << 1)
                            {
                                data[dIndex + x / 8] |= cIndex << (7 - x % 8);
                            }
                            else if (palettes[i].length <= 1 << 4)
                            {
                                if (x % 2 == 0)
                                {
                                    data[dIndex + x / 2] = cast(ubyte)(cIndex << 4);
                                }
                                else
                                {
                                    data[dIndex + x / 2] |= cIndex;
                                }
                            }
                            else
                            {
                                data[dIndex + x] = cast(ubyte) cIndex;
                            }
                        }
                    }
                    dIndex += fStride1;
                }
                fp.rawWrite(data);
                toWrite = false;
            }
            else if (bitmaps[i].indexed && !middleOpacity[i])
            {
                RGBQUAD[] icColors = new RGBQUAD[1 << bitmaps[i].bpp];
                for (int j = 0; j < bitmaps[i].palette.length; j++)
                {
                    icColors[j].rgbRed = bitmaps[i].palette[j].r;
                    icColors[j].rgbGreen = bitmaps[i].palette[j].g;
                    icColors[j].rgbBlue = bitmaps[i].palette[j].b;
                    icColors[j].rgbReserved = 0;
                }
                icColors[bitmaps[i].palette.length .. $] = RGBQUAD(0, 0, 0, 0);
                fp.rawWrite(icColors);
                toWrite = true;
            }
            else if (bitmaps[i].pixelFormat == PixelFormat.Format16bppRgb555LE
                    || bitmaps[i].pixelFormat == PixelFormat.Format32bppArgbLE)
            {
                toWrite = true;
            }
            else if (bitmaps[i].pixelFormat == PixelFormat.Format16bppRgb555BE)
            {
                pixelFormat = PixelFormat.Format16bppRgb555LE;
                toWrite = true;
            }
            else
            {
                if (middleOpacity[i])
                {
                    pixelFormat = PixelFormat.Format32bppArgbLE;
                    toWrite = true;
                }
                else
                {
                    RGBQUAD[] quads = new RGBQUAD[bitmaps[i].width * bitmaps[i].height];
                    int quadsIndex = 0;
                    foreach (int y; bitmaps[i].yBottomUp)
                    {
                        foreach (int x, Color color; bitmaps[i].scanLine(y))
                        {
                            quads[quadsIndex + x] = RGBQUAD(color.b, color.g, color.r, 0);
                        }
                        quadsIndex += bitmaps[i].width;
                    }
                    fp.rawWrite(quads);
                    toWrite = false;
                }
            }
            if (toWrite)
            {
                ubyte[] row = new ubyte[fStride1];
                row[(bitmaps[i].width * bitmaps[i].bpp + 7) / 8 - 1 .. $] = 0;
                for (int y = bitmaps[i].height - 1; y >= 0; y--)
                {
                    bitmaps[i].rawLine(y, row.ptr, 0, pixelFormat, palettes[i]);
                    if (pixelFormat == PixelFormat.Format16bppRgb555LE)
                    {
                        for (int x = 1; x < bitmaps[i].width * 2; x += 2)
                        {
                            row[x] &= 0b01111111;
                        }
                    }
                    fp.rawWrite(row);
                }
            }
            ubyte[] icAND = new ubyte[fStride2 * bitmaps[i].height];
            icAND[] = 0;
            if (!opaque[i])
            {
                int andIndex = 0;
                foreach (int y; bitmaps[i].yBottomUp)
                {
                    foreach (int x, Color color; bitmaps[i].scanLine(y))
                    {
                        if (color.a == 0)
                        {
                            icAND[andIndex + x / 8] |= 1 << (7 - x % 8);
                        }
                    }
                    andIndex += fStride2;
                }
            }
            fp.rawWrite(icAND);
        }
    }
}

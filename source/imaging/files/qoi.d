/**
 * This module provides a codec for the Quite Ok Image Format.
 *
 * See_Also:
 *     [The Quite OK Image Format for Fast, Lossless Compression](https://qoiformat.org/),
 *     [Lossless Image Compression in O(n) Time](https://phoboslab.org/log/2021/11/qoi-fast-lossless-image-compression),
 *     [The QOI File Format Specification](https://phoboslab.org/log/2021/12/qoi-specification)
 *
 * Copyright: Copyright (C) 2026 Valentino Giudice
 * License: BSL-1.0
 * Authors: [Valentino Giudice](https://www.functorfault.net/)
 */
module imaging.files.qoi;

import imaging : Bitmap, Color, PixelFormat, bpp;
import imaging.files : beConv, ImageInfo, ImageLoader, LoadState, SingleImageFormat;
import std.algorithm.comparison : min;
import std.concurrency : Generator, yield;
import std.exception : enforce;
import std.range.interfaces : InputRange;
import std.stdio : File, SEEK_CUR;
import std.typecons : Nullable, nullable;

private align(2) struct QoiHeader
{
    char[4] magic;
    uint width;
    uint height;
    ubyte channels;
    ubyte colorspace;
}

/**
 * Represents an image loader for a file in the Quite Ok Image Format.
 */
public final class QoiLoader : ImageLoader
{
    private File _fp;
    private LoadState _state;
    private ImageInfo _info;
    private bool _linear;

    /**
     * Creates an image loader for a file in the Quite Ok Image Format.
     * Calling this constructor does not perform any read operation or advance the file pointer.
     *
     * Params:
     *     fp =
     *         The file pointer to be used.
     *         It must be open for binary read.
     */
    @safe public this(File fp)
    {
        this._fp = fp;
        this._state = LoadState.BeforeInfo;
    }

    /// The instance of the [QoiFormat] singleton class.
    @property @safe public QoiFormat format() const nothrow
    {
        return QoiFormat.instance();
    }

    /// The current state of the loader.
    @nogc @property @safe public pure LoadState state() const nothrow
    {
        return this._state;
    }

    /// Always 1.
    @nogc @property @safe public pure int length() const nothrow
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
        QoiHeader header;
        if (this._fp.rawRead((&header)[0 .. 1]).length != 1)
        {
            return Nullable!ImageInfo();
        }
        header.width = beConv(header.width);
        header.height = beConv(header.height);
        if (header.magic != "qoif")
        {
            return Nullable!ImageInfo();
        }
        PixelFormat pixelFormat;
        switch (header.channels)
        {
        case 3:
            pixelFormat = PixelFormat.Format24bppRgb;
            break;
        case 4:
            pixelFormat = PixelFormat.Format32bppRgba;
            break;
        default:
            return Nullable!ImageInfo();
        }
        switch (header.colorspace)
        {
        case 0, 1:
            this._linear = !!header.colorspace;
            break;
        default:
            return Nullable!ImageInfo();
        }
        this._state = LoadState.BeforeImage;
        this._info = ImageInfo(QoiFormat.instance(), header.width, header.height, pixelFormat);
        return nullable(this._info);
    }

    private InputRange!Color pixels()
    {
        Color prevPx = Color(0, 0, 0, 255);
        Color[64] array;
        array[] = Color(0, 0, 0, 0);
        ubyte[5] values;
        return new Generator!Color({
            size_t index = 0;
            size_t length = this._info.width * this._info.height;
            while (index < length)
            {
                if (this._fp.rawRead(values[0 .. 1]).length != 1)
                {
                    return;
                }
                Color curPx;
                if (values[0] == 0b11111110)
                {
                    // QOI_OP_RGB
                    if (this._fp.rawRead(values[1 .. 4]).length != 3)
                    {
                        return;
                    }
                    curPx = Color(values[1], values[2], values[3], prevPx.a);
                }
                else if (values[0] == 0b11111111)
                {
                    // QOI_OP_RGBA
                    if (this._fp.rawRead(values[1 .. 5]).length != 4)
                    {
                        return;
                    }
                    curPx = Color(values[1], values[2], values[3], values[4]);
                }
                else if (values[0] >> 6 == 0b00)
                {
                    // QOI_OP_INDEX
                    curPx = array[values[0]];
                }
                else if (values[0] >> 6 == 0b01)
                {
                    // QOI_OP_DIFF
                    ubyte dr = cast(ubyte)((values[0] >> 4 & 0b11) - 2);
                    ubyte dg = cast(ubyte)((values[0] >> 2 & 0b11) - 2);
                    ubyte db = cast(ubyte)((values[0] & 0b11) - 2);
                    curPx = Color(cast(ubyte)(prevPx.r + dr),
                        cast(ubyte)(prevPx.g + dg), cast(ubyte)(prevPx.b + db), prevPx.a);
                }
                else if (values[0] >> 6 == 0b10)
                {
                    // QOI_OP_LUMA
                    if (this._fp.rawRead(values[1 .. 2]).length != 1)
                    {
                        return;
                    }
                    ubyte dg = cast(ubyte)((values[0] & 0b111111) - 32);
                    ubyte dr_dg = cast(ubyte)((values[1] >> 4) - 8);
                    ubyte db_dg = cast(ubyte)((values[1] & 0xF) - 8);
                    ubyte dr = cast(ubyte)(dr_dg + dg);
                    ubyte db = cast(ubyte)(db_dg + dg);
                    curPx = Color(cast(ubyte)(prevPx.r + dr),
                        cast(ubyte)(prevPx.g + dg), cast(ubyte)(prevPx.b + db), prevPx.a);
                }
                else if (values[0] >> 6 == 0b11)
                {
                    // QOI_OP_RUN
                    int runLength = (values[0] & 0b111111) + 1;
                    curPx = prevPx;
                    if (runLength > length - index)
                    {
                        return;
                    }
                    for (int i = 0; i < runLength - 1; i++)
                    {
                        yield(curPx);
                    }
                    index += runLength - 1;
                }
                int indexPosition = (curPx.r * 3 + curPx.g * 5 + curPx.b * 7 + curPx.a * 11) % 64;
                yield(curPx);
                array[indexPosition] = curPx;
                prevPx = curPx;
                index++;
            }
        });
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
        if (this.state == LoadState.BeforeInfo)
        {
            this.nextInfo();
            if (this.state == LoadState.Invalid)
            {
                return null;
            }
        }
        assert(this.state == LoadState.BeforeImage);
        size_t index = 0;
        size_t length = this._info.width * this._info.height;
        void[] data;
        this._state = LoadState.Invalid;
        if (this._info.pixelFormat == PixelFormat.Format32bppRgba)
        {
            Color[] pixelData = new Color[length];
            foreach (Color pixel; this.pixels)
            {
                pixelData[index++] = pixel;
            }
            data = pixelData;
        }
        else
        {
            ubyte[3][] pixelData = new ubyte[3][length];
            foreach (Color pixel; this.pixels)
            {
                if (pixel.a != 255)
                {
                    return null;
                }
                version (BigEndian)
                {
                    pixelData[index] = [pixel.r, pixel.g, pixel.b];
                }
                else version (LittleEndian)
                {
                    pixelData[index] = [pixel.b, pixel.g, pixel.r];
                }
                index++;
            }
            data = pixelData;
        }
        if (index != length)
        {
            return null;
        }
        ubyte[8] streamEnd;
        if (this._fp.rawRead(streamEnd) != [0, 0, 0, 0, 0, 0, 0, 1])
        {
            return null;
        }
        this._state = LoadState.End;
        return new Bitmap(this._info.width, this._info.height, 0,
                this._info.width * this._info.pixelFormat.bpp / 8,
                this._info.pixelFormat, null, false, data);
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
        size_t index = 0;
        foreach (Color pixel; this.pixels)
        {
            index++;
        }
        this._state = LoadState.Invalid;
        if (index == this._info.width * this._info.height)
        {
            ulong p = this._fp.tell;
            this._fp.seek(8, SEEK_CUR);
            if (this._fp.tell - p == 8)
            {
                this._state = LoadState.End;
            }
        }
    }
}

/**
 * Represents the Quite Ok Image Format.
 */
public final class QoiFormat : SingleImageFormat
{
    private static QoiFormat _instance;

    @safe private pure this() nothrow
    {
    }

    /**
     * Returns the instance of the singleton [QoiFormat] class.
     *
     * Returns: The singular instance of this class.
     */
    @safe public static QoiFormat instance() nothrow
    {
        if (_instance is null)
        {
            _instance = new QoiFormat();
        }
        return _instance;
    }

    /**
     * Checks whether a file is in the Quite Ok Image Format, based on its first bytes.
     *
     * Params:
     *     head = The beginning of the file.
     *
     * Returns:
     *     `true` if the file is in the Quite Ok Image Format, `false` otherwise.
     *     If not enough bytes are provided, `false` is returned.
     */
    @nogc @safe public override bool checkFormat(const ubyte[] head) const nothrow
    {
        return head[0 .. 4] == "qoif";
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
    @safe public override QoiLoader loader(File fp) const
    {
        return new QoiLoader(fp);
    }

    /**
     * Exports the given image to the given Quite Ok Image Format file.
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
     *     forceAlpha =
     *         Whether the alpha channel is to be included even if the image is fully opaque.
     *         It can be useful for testing purposes.
     *         It defaults to `false`.
     */
    public void save(File fp, const Bitmap bmp, bool forceAlpha) const
    in (bmp !is null)
    {
        enforce(bmp.valid());
        QoiHeader header;
        header.magic = "qoif";
        header.width = beConv(bmp.width);
        header.height = beConv(bmp.height);
        header.channels = (!forceAlpha && bmp.opaque()) ? 3 : 4;
        header.colorspace = 0;
        fp.rawWrite([header]);
        Color prevPx = Color(0, 0, 0, 255);
        Color[64] array;
        array[] = Color(0, 0, 0, 0);
        ubyte[5] values;
        int eqRun = 0;
        foreach (int y; bmp.yTopDown)
        {
            foreach (Color curPx; bmp.scanLine(y))
            {
                int indexPosition = (curPx.r * 3 + curPx.g * 5 + curPx.b * 7 + curPx.a * 11) % 64;
                if (curPx == prevPx)
                {
                    eqRun++;
                }
                else
                {
                    while (eqRun > 0)
                    {
                        // QOI_OP_RUN
                        ubyte run = cast(ubyte) min(eqRun, 62);
                        values[0] = cast(ubyte)(0b11 << 6 | (run - 1));
                        fp.rawWrite(values[0 .. 1]);
                        eqRun -= run;
                    }
                    if (array[indexPosition] == curPx)
                    {
                        // QOI_OP_INDEX
                        values[0] = cast(ubyte) indexPosition;
                        fp.rawWrite(values[0 .. 1]);
                    }
                    else if (curPx.a != prevPx.a)
                    {
                        // QOI_OP_RGBA
                        values = [
                            0b11111111, curPx.r, curPx.g, curPx.b, curPx.a
                        ];
                        fp.rawWrite(values);
                    }
                    else
                    {
                        ubyte dr = cast(ubyte)(curPx.r - prevPx.r);
                        ubyte dg = cast(ubyte)(curPx.g - prevPx.g);
                        ubyte db = cast(ubyte)(curPx.b - prevPx.b);
                        if (cast(ubyte)(dr + 2) <= 3 && cast(ubyte)(dg + 2) <= 3
                                && cast(ubyte)(db + 2) <= 3)
                        {
                            // QOI_OP_DIFF
                            values[0] = cast(ubyte)(0b01 << 6 | (dr + 2) << 4 | (dg + 2) << 2 | (
                                    db + 2));
                            fp.rawWrite(values[0 .. 1]);
                        }
                        else
                        {
                            ubyte dr_dg = cast(ubyte)(dr - dg);
                            ubyte db_dg = cast(ubyte)(db - dg);
                            if (cast(ubyte)(dg + 32) <= 63
                                    && cast(ubyte)(dr_dg + 8) <= 15 && cast(ubyte)(db_dg + 8) <= 15)
                            {
                                // QOI_OP_LUMA
                                values[0] = cast(ubyte)(0b10 << 6 | (dg + 32));
                                values[1] = cast(ubyte)((dr_dg + 8) << 4 | (db_dg + 8));
                                fp.rawWrite(values[0 .. 2]);
                            }
                            else
                            {
                                // QOI_OP_RGB
                                values[0 .. 4] = [
                                    0b11111110, curPx.r, curPx.g, curPx.b
                                ];
                                fp.rawWrite(values[0 .. 4]);
                            }
                        }
                    }
                }
                array[indexPosition] = curPx;
                prevPx = curPx;
            }
        }
        while (eqRun > 0)
        {
            // QOI_OP_RUN
            ubyte run = cast(ubyte)(min(eqRun, 62));
            values[0] = cast(ubyte)(0b11 << 6 | (run - 1));
            fp.rawWrite(values[0 .. 1]);
            eqRun -= run;
        }
        ubyte[8] streamEnd;
        streamEnd[0 .. 7] = 0;
        streamEnd[7] = 1;
        fp.rawWrite(streamEnd);
    }

    /// ditto
    public override void save(File fp, const Bitmap bmp) const
    in (bmp !is null)
    {
        this.save(fp, bmp, false);
    }
}

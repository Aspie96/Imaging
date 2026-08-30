/**
 * This module provides a codec for the Animated PNG format.
 *
 * See_Also:
 *     [APNG Specification](https://wiki.mozilla.org/APNG_Specification),
 *     [APNG: frame-based animation](https://www.w3.org/TR/png/#apng-frame-based-animation)
 *
 * Copyright: Copyright (C) 2026 Valentino Giudice
 * License: BSL-1.0
 * Authors: [Valentino Giudice](https://www.functorfault.net/)
 */
module imaging.files.apng;

import imaging : Bitmap, bpp, Color, indexed, PixelFormat, Rectangle;
import imaging.extra : Animation;
import imaging.files : AnimatedImageFormat, AnimatedImageLoader, ImageInfo, LoadState;
import imaging.files.png : BasePngLoader, BlendOp, ColorType, Data_acTL,
    Data_fcTL, Data_IHDR, DisposeOp, encode, pngSignature, writeChunk;
import std.math.operations : isClose;
import std.math.rounding : ceil, round;
import std.algorithm.comparison : max, min;
import std.algorithm.searching : all, count;
import std.array : array;
import std.exception : enforce;
import std.stdio : File;
import std.typecons : Nullable;
import std.zlib : compress;

// Finds the log base 2 of an N-bit integer in O(lg(N)) operations with multiply and lookup: https://graphics.stanford.edu/~seander/bithacks.html#IntegerLogDeBruijn
private uint next2Power(uint v)
{
    v--;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    v++;
    return v;
}

private void numDen(double v, out ushort num, out ushort den)
{
    ushort delayNum;
    ushort delayDen;
    double precision = 0.0000001;
    if (v <= precision)
    {
        delayNum = 0;
        delayDen = 0;
    }
    else
    {
        double d100 = v * 100;
        int rounded = cast(int) round(d100);
        if (d100 < short.max && isClose(d100 - rounded, 0, precision * 100))
        {
            delayNum = cast(ushort) rounded;
            delayDen = 0;
        }
        else
        {
            ushort factor;
            if (v < 1)
            {
                factor = 1;
            }
            else
            {
                uint pow2 = next2Power(cast(uint) ceil(v));
                factor = (1 << 14) / pow2;
            }
            delayNum = cast(ushort) round(v * factor);
            delayDen = factor;
        }
    }
}

/**
 * Represents an image loader for an Animated PNG file.
 *
 * For a non-animated PNG file, it will load a one-frame animation with a duration of 0 seconds.
 */
public final class ApngLoader : AnimatedImageLoader
{
    private BasePngLoader!true _loader;

    /**
     * Creates an image loader for a Portable Network Graphics file.
     * Calling this constructor performs read operations and advances the file pointer.
     *
     * Params:
     *     fp =
     *         The file pointer to be used.
     *         It must be open for binary read.
     *     maxChunks =
     *         The maximum amount of chunks to be read from the file.
     *         If the file has more chunks, it will be deemed to be invalid.
     */
    public this(File fp, int maxChunks = 1024)
    {
        this._loader = BasePngLoader!true(fp, ApngFormat.instance(), maxChunks);
    }

    /// The instance of the [ApngFormat] singleton class.
    @property @safe public ApngFormat format() const nothrow
    {
        return ApngFormat.instance();
    }

    /// The current state of the loader.
    @nogc @property @safe public LoadState state() const nothrow
    {
        return this._loader.state;
    }

    /// The number of frames in the animation.
    /// Always 1 if the file is actually a non-animated PNG file.
    @nogc @property @safe public pure int length() const nothrow
    {
        return this._loader.length;
    }

    /// The width of the frames in the file.
    @nogc @property @safe public pure int width() const nothrow
    {
        return this._loader.width;
    }

    /// The height of the frames in the file.
    @nogc @property @safe public pure int height() const nothrow
    {
        return this._loader.height;
    }

    /// The total duration of the animation, in seconds.
    @nogc @property @safe public pure double duration() const nothrow
    {
        return this._loader.duration;
    }

    /**
     * Tries to read information about the next frame in the file.
     * The [state] property must be equal to either [LoadState.BeforeInfo] or [LoadState.BeforeImage].
     * The function sets it to a value representing the new state of the loader.
     *
     * Returns:
     *     An [ImageInfo] instance if data is read correctly from the file.
     *     In this case the [state] property is set to [LoadState.BeforeImage].
     *     A null value if invalid data is encountered or the file contains no more frames.
     *     In this case the [state] property is set to either [LoadState.Invalid] or [LoadState.End].
     */
    public Nullable!ImageInfo nextInfo()
    in (this.state == LoadState.BeforeInfo || this.state == LoadState.BeforeImage)
    {
        return this._loader.nextInfo();
    }

    /**
     * Tries to read the next frame in the file.
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
        return this._loader.nextImage();
    }

    /**
     * Skips the next frame in the file.
     * The [state] property must be equal to either [LoadState.BeforeInfo] or [LoadState.BeforeImage].
     * The function sets it to a value representing the new state of the loader.
     */
    public void skipImage()
    in (this.state == LoadState.BeforeImage || this.state == LoadState.BeforeInfo)
    {
        this._loader.skipImage();
    }

    /**
     * Tries to read the whole animation from the file.
     * The function can only be called if the [nextInfo], [nextImage] and [skipImage] functions have never been called on this loader.
     * The [state] property is set by the function to a value representing the new state of the loader.
     *
     * Returns:
     *     An [Animation] instance if data is read correctly from the file.
     *     In this case the [state] property is set to [LoadState.End].
     *     A null value if invalid data is encountered.
     *     In this case the [state] property is set to [LoadState.Invalid].
     */
    public Animation wholeAnimation()
    in (this.state == LoadState.BeforeInfo)
    {
        Bitmap[] frames = new Bitmap[this.length];
        double[] durations = new double[this.length];
        for (int i = 0; i < this.length; i++)
        {
            this.nextInfo();
            if (this.state == LoadState.Invalid)
            {
                return null;
            }
            durations[i] = this.duration;
            frames[i] = this.nextImage();
            if (this.state == LoadState.Invalid)
            {
                return null;
            }
        }
        return new Animation(frames, durations);
    }
}

/**
 * Represents the Animated PNG format.
 */
public final class ApngFormat : AnimatedImageFormat
{
    private static ApngFormat _instance;

    @safe private pure this() nothrow
    {
    }

    /**
     * Returns the instance of the singleton class [ApngFormat].
     *
     * Returns: The singular instance of this class.
     */
    @safe public static ApngFormat instance() nothrow
    {
        if (_instance is null)
        {
            _instance = new ApngFormat();
        }
        return _instance;
    }

    /**
     * Checks whether a file is a (possibly animated) PNG file, based on its first bytes.
     * It doesn't distinguish between animated and non-animated files.
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
     * Creates a loader for the given file.
     * The loader, upon creation, reads information about the whole file, learning the number of frames it contains, as well as the width and height of the frames.
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
    public override ApngLoader loader(File fp) const
    {
        return new ApngLoader(fp);
    }

    /**
     * Exports the given animation to the given file.
     * After the operation, the given file pointer is set to the end of the written data (also the end of the file).
     *
     * Params:
     *     fp =
     *         The file pointer to be used.
     *         It must be open for binary write.
     *         Any data preceding the file pointer is left untouched.
     *     anim =
     *         The animation to be exported.
     *         It cannot be null.
     *     staticImage =
     *         The default static decode image the file will decode to if read as a standard PNG file.
     *         This may be null, in which case the first frame of the animation is used as the default static image.
     *         Defaults to `null`.
     */
    public void save(File fp, const Animation anim, const Bitmap staticImage) const
    in
    {
        assert(anim !is null);
        if (staticImage !is null)
        {
            assert(staticImage.width == anim.width);
            assert(staticImage.height == anim.height);
        }
    }
    do
    {
        enforce(anim.valid());
        if (staticImage !is null)
        {
            enforce(staticImage.valid());
        }
        fp.rawWrite(pngSignature);
        ColorType colorType;
        immutable(Color)[] palette;
        const Bitmap firstImage = staticImage is null ? anim.frames[0] : staticImage;
        switch (firstImage.pixelFormat)
        {
        case PixelFormat.Format1bppIndexed, PixelFormat.Format4bppIndexed,
                PixelFormat.Format8bppIndexed:
                palette = firstImage.palette;
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
        foreach (size_t i, const Bitmap frame; anim.frames)
        {
            if (staticImage !is null || i > 0)
            {
                switch (frame.pixelFormat)
                {
                case PixelFormat.Format1bppIndexed, PixelFormat.Format4bppIndexed,
                        PixelFormat.Format8bppIndexed:
                        if (colorType == ColorType.Indexed && frame.palette != palette)
                    {
                        if (all!(c => c.a == 255)(frame.palette) && all!(c => c.a == 255)(palette))
                        {
                            colorType = ColorType.RgbTriple;
                        }
                        else
                        {
                            colorType = ColorType.Rgba;
                        }
                    }
            else if (colorType == ColorType.Grayscale)
                    {
                        if (all!(c => c.a == 255)(frame.palette))
                        {
                            if (!all!(c => (c.r == c.g && c.g == c.b))(frame.palette))
                            {
                                colorType = ColorType.RgbTriple;
                            }
                        }
                        else
                        {
                            colorType = ColorType.Rgba;
                        }
                    }
                    else if (colorType == ColorType.RgbTriple
                            && !all!(c => c.a == 255)(frame.palette))
                    {
                        colorType = ColorType.Rgba;
                    }
                    break;
                case PixelFormat.Format8bppGray:
                    if (colorType == ColorType.Indexed)
                    {
                        if (all!(c => c.a == 255)(palette))
                        {
                            if (all!(c => (c.r == c.g && c.g == c.b))(palette))
                            {
                                colorType = ColorType.Grayscale;
                            }
                            else
                            {
                                colorType = ColorType.RgbTriple;
                            }
                        }
                        else
                        {
                            colorType = ColorType.Rgba;
                        }
                    }
                    break;
                case PixelFormat.Format32bppArgbBE, PixelFormat.Format32bppArgbLE,
                        PixelFormat.Format32bppRgbaBE,
                        PixelFormat.Format32bppRgbaLE:
                        colorType = ColorType.Rgba;
                    break;
                default:
                    if (colorType == ColorType.Indexed && !all!(c => c.a == 255)(palette))
                    {
                        colorType = ColorType.Rgba;
                    }
                    else
                    {
                        colorType = ColorType.RgbTriple;
                    }
                    break;
                }
            }
        }
        ubyte bitDepth;
        if (colorType == ColorType.Indexed)
        {
            uint pow2 = next2Power(cast(uint) palette.length);
            if (pow2 <= 2)
            {
                bitDepth = 1;
            }
            else if (pow2 <= 16)
            {
                bitDepth = 4;
            }
            else
            {
                assert(pow2 <= 256);
                bitDepth = 8;
            }
        }
        else
        {
            bitDepth = 8;
            palette = null;
        }
        Data_IHDR d_IHDR = Data_IHDR(anim.width, anim.height, bitDepth, colorType, 0, 0, 0);
        assert(d_IHDR.valid);
        writeChunk(fp, "IHDR", d_IHDR);
        Data_acTL d_acTL = Data_acTL(cast(uint) anim.length, anim.plays);
        writeChunk(fp, "acTL", d_acTL);
        if (colorType == ColorType.Indexed)
        {
            ubyte[3][] d_PLTE = new ubyte[3][palette.length];
            int lastAlpha = -1;
            for (int i = 0; i < palette.length; i++)
            {
                d_PLTE[i] = [palette[i].r, palette[i].g, palette[i].b];
                if (palette[i].a != 255)
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
                    d_tRNS[i] = palette[i].a;
                }
                writeChunk(fp, "tRNS", d_tRNS);
            }
        }
        uint sequenceNumber = 0;
        ushort delayNum;
        ushort delayDen;
        ubyte[] data;
        if (staticImage is null)
        {
            numDen(anim.durations[0], delayNum, delayDen);
            Data_fcTL d_fcTL = Data_fcTL(sequenceNumber++, anim.width, anim.height, 0, 0, delayNum,
                    delayDen, DisposeOp.APNG_DISPOSE_OP_NONE, BlendOp.APNG_BLEND_OP_SOURCE);
            writeChunk(fp, "fcTL", d_fcTL);
            data = encode(anim.frames[0], colorType, bitDepth);
        }
        else
        {
            data = encode(staticImage, colorType, bitDepth);
        }
        ubyte[] dIDAT = compress(data);
        writeChunk(fp, "IDAT", dIDAT);
        Bitmap prevImg = cast(Bitmap) staticImage;
        foreach (size_t i, const Bitmap frame; anim.frames)
        {
            if (staticImage !is null || i > 0)
            {
                int xMin = int.max;
                int yMin = int.max;
                int xMax = -1;
                int yMax = -1;
                assert(prevImg !is null);
                for (int y = 0; y < frame.height; y++)
                {
                    auto r1 = prevImg.scanLine(prevImg.yTopDown[y]);
                    auto r2 = frame.scanLine(frame.yTopDown[y]);
                    for (int x = 0; x < frame.width; x++)
                    {
                        if (r1[x] != r2[x])
                        {
                            xMin = min(x, xMin);
                            xMax = max(x, xMax);
                            yMin = min(y, yMin);
                            yMax = max(y, yMax);
                        }
                    }
                }
                Rectangle rect;
                if (xMax == -1)
                {
                    rect = Rectangle(0, 0, 1, 1);
                }
                else
                {
                    rect = Rectangle(xMin, yMin, xMax - xMin + 1, yMax - yMin + 1);
                }
                //Rectangle rect = Rectangle(0, 0, anim.width, anim.height);
                numDen(anim.durations[i], delayNum, delayDen);
                Data_fcTL d_fcTL = Data_fcTL(sequenceNumber++, rect.width,
                        rect.height, rect.x, rect.y, delayNum, delayDen,
                        DisposeOp.APNG_DISPOSE_OP_NONE, BlendOp.APNG_BLEND_OP_SOURCE);
                writeChunk(fp, "fcTL", d_fcTL);
                const Bitmap subFrame = frame.slice(rect);
                data = encode(subFrame, colorType, bitDepth);
                ubyte[] frameData = compress(data);
                ubyte[4] sequenceNumberBe = [
                    sequenceNumber >> 24, sequenceNumber >> 16 & 0xFF,
                    sequenceNumber >> 8 & 0xFF, sequenceNumber & 0xFF,
                ];
                sequenceNumber++;
                ubyte[] dfdAT = sequenceNumberBe ~ frameData;
                writeChunk(fp, "fdAT", dfdAT);
            }
            prevImg = cast(Bitmap) frame;
        }
        for (size_t i = staticImage is null; i < anim.length; i++)
        {

        }
        writeChunk(fp, "IEND", []);
    }

    /// ditto
    public override void save(File fp, const Animation anim) const
    in (anim !is null)
    {
        this.save(fp, anim, null);
    }
}

/**
 * This module provides functionalities for exporting images to file and importing images from files.
 *
 * Copyright: Copyright (C) 2026 Valentino Giudice
 * License: BSL-1.0
 * Authors: [Valentino Giudice](https://www.functorfault.net/)
 */
module imaging.files;

import imaging : alignSize, Bitmap, bpp, getPixelDataSize, pixelDataAlloc, PixelFormat;
import imaging.extra : Animation;
import imaging.files.apng : ApngFormat;
import imaging.files.bmp : BmpFormat;
import imaging.files.ico : IcoFormat;
import imaging.files.png : checkAnimated, PngFormat, pngSignature;
import imaging.files.qoi : QoiFormat;
import std.algorithm.mutation : reverse;
import std.algorithm.searching : all;
import std.array : array;
import std.range.primitives : isInfinite;
import std.stdio : File, SEEK_CUR;
import std.traits : ForeachType, isIterable;
import std.typecons : Nullable;

// Importing std.bitmanip.swapEndian would be better, but: https://github.com/dlang/dmd/issues/17923
@nogc @trusted private pure T swapEndian(T)(T val) if (__traits(isIntegral, T))
{
    reverse((cast(ubyte*)&val)[0 .. T.sizeof]);
    return val;
}

@nogc @safe private pure T swapEndian(T)(T vals) if (__traits(isStaticArray, T))
{
    foreach (ref v; vals)
    {
        v = beConv(v);
    }
    return vals;
}

@nogc @safe private pure T swapEndian(T)(T val) if (is(T == struct))
{
    foreach (ref part; val.tupleof)
    {
        part = swapEndian(part);
    }
    return val;
}

@nogc @safe package(imaging.files) pure T leConv(T)(T val)
{
    version (BigEndian)
    {
        return swapEndian(val);
    }
    else version (LittleEndian)
    {
        return val;
    }
    else
    {
        static assert(0);
    }
}

@nogc @safe package(imaging.files) pure T beConv(T)(T val)
{
    version (BigEndian)
    {
        return val;
    }
    else version (LittleEndian)
    {
        return swapEndian(val);
    }
    else
    {
        static assert(0);
    }
}

/**
 * Represents information about an image stored in a file.
 */
public struct ImageInfo
{
    /// The file format of the image.
    ImageFormat format;

    /// The width of the image.
    int width;

    /// The height of the image.
    int height;

    /// The pixel format of the image.
    PixelFormat pixelFormat;

    /**
     * Computes the minimum stride of the pixel data of an image with the width, height and pixel format specified in this instance.
     * [width] and [height] must both be greater than 0.
     *
     * Returns: The stride of the pixel data of an image with the properties specified in this instance.
     */
    @nogc @safe public pure ulong stride() nothrow return
    in (this.width > 0 && this.height > 0)
    out (result; stride % this.pixelFormat.alignSize == 0)
    {
        ulong stride;
        getPixelDataSize(this.width, this.height, this.pixelFormat, stride);
        return stride;
    }

    /**
     * Computes the minimum size of the pixel data of an image with the width, height and pixel format specified in this instance.
     * [width] and [height] must both be greater than 0.
     *
     * Returns:
     *     The size of the pixel data of an image with the properties specified in this instance.
     *     This is the size of a pixel data array as it is read by a loader.
     */
    @nogc @safe public pure ulong size() nothrow return
    in (this.width > 0 && this.height > 0)
    {
        return getPixelDataSize(this.width, this.height, this.pixelFormat);
    }
}

/**
 * Represents the state of an image loader.
 */
public enum LoadState
{
    /// Specifies that the next data to be read from the file is image information represented through the [ImageInfo] struct.
    BeforeInfo,

    /// Specifies that the next data to be read from the file is an actual image represented through the [imaging.Bitmap] class.
    BeforeImage,

    /// Specifies that the file has ended.
    End,

    /// Represents an invalid state for the loader.
    Invalid
}

/**
 * Represents an object used to read image information and images from a file in a known format.
 *
 * An image file contains one or more images.
 * If the image format supports multiple images, which is the case for multi-image and animated file formats, the loader, upon creation, reads information about the whole file, learning the number of images it contains ([length] property).
 * The instantiation of a loader for a single-image format does not advance the file pointer.
 * The loader than reads image information and actual images in an alternating fashion.
 * That is to say that information about each image is read right before the image itself.
 * If all images are successfully read from the file, the [state] property is set to [LoadState.End] and the file pointer is set at the end of the image file, according to its format, before any trailing data.
 * Invalid image data does not cause errors or exceptions.
 * Instead, it leads to the [state] property of the loader being set to [LoadState.Invalid].
 * In that case, the position of the file pointer is unspecified.
 */
public interface ImageLoader
{
    /// The image file format for this loader.
    @property @safe ImageFormat format() const nothrow
    out (result; result !is null);

    /// The current state of the loader.
    @nogc @property @safe pure LoadState state() const nothrow;

    /// The total amount of images in the file.
    @nogc @property @safe pure int length() const nothrow
    in (this.state != LoadState.Invalid)
    out (result; result > 0);

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
    Nullable!ImageInfo nextInfo()
    in (this.state == LoadState.BeforeInfo || this.state == LoadState.BeforeImage)
    out (result)
    {
        if (result.isNull)
        {
            assert(this.state == LoadState.Invalid || this.state == LoadState.End);
        }
        else
        {
            assert(this.state == LoadState.BeforeImage);
            assert(result.get.format is this.format);
        }
    }

    /**
     * Tries to read the next image in the file.
     * The [state] property must be equal to either [LoadState.BeforeInfo] or [LoadState.BeforeImage].
     * The function sets it to a value representing the new state of the loader.
     *
     * Returns:
     *     A [Bitmap] instance if data is read correctly from the file.
     *     Its [Bitmap.skipX] property will be 0 and it will have newly allocated pixel data with the smallest possible size for its width, height and pixel format.
     *     In this case the [state] property is set to either [LoadState.BeforeInfo] or [LoadState.End].
     *     A null value if invalid data is encountered.
     *     In this case the [state] property is set to [LoadState.Invalid].
     */
    Bitmap nextImage()
    in (this.state == LoadState.BeforeImage || this.state == LoadState.BeforeInfo)
    out (result)
    {
        if (result is null)
        {
            assert(this.state == LoadState.Invalid);
        }
        else
        {
            assert(this.state == LoadState.BeforeInfo || this.state == LoadState.End);
            assert(result.valid());
            assert(result.skipX == 0);
            ulong stride;
            ulong size = getPixelDataSize(result.width, result.height, result.pixelFormat, stride);
            assert(result.stride == stride);
            assert(result.data.length == size);
        }
    }

    /**
     * Tries to skip the next image in the file.
     * The [state] property must be equal to either [LoadState.BeforeInfo] or [LoadState.BeforeImage].
     * The function sets it to a value representing the new state of the loader.
     */
    void skipImage()
    in (this.state == LoadState.BeforeImage || this.state == LoadState.BeforeInfo)
    out (; this.state == LoadState.Invalid || this.state == LoadState.BeforeInfo
            || this.state == LoadState.End);
}

/**
 * Represents an object used to read image information and images from a file in a known animated-image format.
 *
 * An animatd image format contains one or more frames, all of which with the same width and height.
 * The loader, upon creation, reads information about the whole file, learning the number of frames it contains ([length] property), as well as their width ([width] property) and height ([height] property).
 */
public interface AnimatedImageLoader : ImageLoader
{
    /// The animated image file format for this loader.
    @property @safe AnimatedImageFormat format() const nothrow
    out (result; result !is null);

    /// The width of the frames in the file.
    @nogc @property @safe pure int width() const nothrow;

    /// The height of the frames in the file.
    @nogc @property @safe pure int height() const nothrow;

    /// The total duration of the animation, in seconds.
    @nogc @property @safe pure double duration() const nothrow;

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
    Animation wholeAnimation()
    in (this.state == LoadState.BeforeInfo)
    out (result)
    {
        if (result is null)
        {
            assert(this.state == LoadState.Invalid);
        }
        else
        {
            assert(this.state == LoadState.End);
            assert(result.valid());
        }
    }
}

private T findRegistered(T)(T[] registered, const ubyte[] head)
{
    foreach (T f; registered)
    {
        if (f.checkFormat(head))
        {
            return f;
        }
    }
    return null;
}

/**
 * Represents an image file format.
 *
 * This abstract class cannot be inherited from directly.
 * The [SingleImageFormat], [MultiImageFormat] or [AnimatedImageFormat] class are to be inherited from instead.
 * Each image format should be represented by a singleton class.
 */
public abstract class ImageFormat
{
    private static ImageFormat[] _registered = [];

    @nogc @safe private pure this() nothrow
    {
    }

    /**
     * Registers a user-defined file format for future use.
     */
    @safe public static void register(ImageFormat format) nothrow
    in (format !is null)
    {
        if (SingleImageFormat f = cast(SingleImageFormat) format)
        {
            SingleImageFormat._registered ~= [f];
        }
        else if (MultiImageFormat f = cast(MultiImageFormat) format)
        {
            MultiImageFormat._registered ~= [f];
        }
        else
        {
            AnimatedImageFormat f = cast(AnimatedImageFormat) format;
            assert(f !is null);
            AnimatedImageFormat._registered ~= [f];
        }
        _registered ~= [format];
    }

    /**
     * Attempts to find the correct format for the given file.
     * The position of the given file pointer is reset to its original position after use.
     * Registered user-defined formats are prioritized over default formats.
     *
     * Params:
     *     fp =
     *         The file pointer to be used.
     *         It must be open for binary read.
     *         It must point to the beginning of the image file, which may be part of a larger file.
     *         Any data preceding the file pointer is ignored.
     *
     * Returns:
     *         The found format, if any, `null` otherwise.
     */
    public static ImageFormat format(ref File fp)
    {
        ubyte[16] bytes;
        ubyte[] head = fp.rawRead(bytes[]);
        fp.seek(-(cast(int) head.length), SEEK_CUR);
        ImageFormat f = findRegistered(_registered, head);
        if (f !is null)
        {
            return f;
        }
        if (head[0 .. 8] == pngSignature)
        {
            if (checkAnimated(fp, false))
            {
                return ApngFormat.instance();
            }
            return PngFormat.instance();
        }
        f = SingleImageFormat.defaultFormat(head);
        if (f !is null)
        {
            return f;
        }
        f = MultiImageFormat.defaultFormat(head);
        return f;
    }

    /// Whether an image in this format may contain multiple images.
    /// `false` for [SingleImageFormat] instances and `true` for [MultiImageFormat] and [AnimatedImageFormat] instances.
    @nogc @property @safe public abstract pure bool multi() const nothrow;

    /**
     * Checks whether a file is in this format, based on its first bytes.
     *
     * Params:
     *     head =
     *         The beginning of the file.
     *         This should be the first 16 bytes of the file if the file is at least 16 bytes long and the while file if it isn't.
     *
     * Returns:
     *     `true` if the file is in this format, `false` otherwise.
     *     If not enough bytes are provided, `false` is returned.
     */
    public abstract bool checkFormat(const ubyte[] head) const nothrow;

    /**
     * Creates an image loader for the given file.
     * If this is a single-image format, calling this function does not perform any read operation or advance the file pointer.
     * Otherwise, the loader, upon creation, reads information about the whole file, learning the number of images it contains.
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
    public abstract ImageLoader loader(ref File fp) const;
    /*out(result)
    {
        assert(result.state == LoadState.BeforeInfo || result.state == LoadState.Invalid);
        assert(result.format is this);
    }*/

    /// Instance of the singleton [BmpFormat] class for the Windows Bitmap Format for device-independent bitmaps.
    @safe public static BmpFormat bmp() nothrow
    {
        return BmpFormat.instance();
    }

    /// Instance of the singleton [QoiFormat] class for the Quite Ok Image Format-
    @safe public static QoiFormat qoi() nothrow
    {
        return QoiFormat.instance();
    }

    @safe public static PngFormat png() nothrow
    {
        return PngFormat.instance();
    }

    @safe public static IcoFormat ico() nothrow
    {
        return IcoFormat.instance();
    }

    @safe public static ApngFormat apng() nothrow
    {
        return ApngFormat.instance();
    }
}

/**
 * Represents a file format which stores exactly one image per file.
 */
public abstract class SingleImageFormat : ImageFormat
{
    private static SingleImageFormat[] _registered = [];

    /**
     * Base constructor for the [SingleImageFormat] class.
     */
    @nogc @safe public pure this() nothrow
    {
    }

    /// Always `false`.
    @nogc @property @safe public final override pure bool multi() const nothrow
    out (result; !result)
    {
        return false;
    }

    @safe private static SingleImageFormat defaultFormat(const ubyte[] head) nothrow
    {
        if (head[0 .. 2] == "BM")
        {
            return BmpFormat.instance();
        }
        if (head[0 .. 4] == "qoif")
        {
            return QoiFormat.instance();
        }
        if (head[0 .. 8] == pngSignature)
        {
            return PngFormat.instance();
        }
        return null;
    }

    /**
     * Attempts to find the correct single-image format for a file.
     *
     * Params:
     *     head =
     *         The beginning of the file.
     *         This should be the first 16 bytes of the file if the file is at least 16 bytes long and the while file if it isn't.
     *
     * Returns:
     *         The found single-image format, if any, `null` otherwise.
     */
    private static SingleImageFormat format(const ubyte[] head)
    {
        foreach (SingleImageFormat f; _registered)
        {
            if (f.checkFormat(head))
            {
                return f;
            }
        }
        return defaultFormat(head);
    }

    /**
     * Attempts to find the correct single-image format for the given file.
     * The position of the given file pointer is reset to its original position after use.
     * Registered user-defined formats are prioritized over default formats.
     *
     * Params:
     *     fp =
     *         The file pointer to be used.
     *         It must be open for binary read.
     *         It must point to the beginning of the image file, which may be part of a larger file.
     *         Any data preceding the file pointer is ignored.
     *
     * Returns:
     *         The found single-image format, if any, `null` otherwise.
     */
    public static SingleImageFormat format(ref File fp)
    {
        ubyte[16] bytes;
        ubyte[] head = fp.rawRead(bytes[]);
        fp.seek(-(cast(int) head.length), SEEK_CUR);
        return format(head);
    }

    /**
     * Creates an image loader for the image in the given file.
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
    public abstract override ImageLoader loader(ref File fp) const nothrow
    out (result)
    {
        if (result.state == LoadState.BeforeInfo)
        {
            assert(result.length == 1);
        }
    }

    /**
     * Exports the given image to the given file in this format.
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
    public abstract void save(ref File fp, const Bitmap bmp) const
    in (bmp !is null);
}

/**
 * Represents a file format which may store more than one image per file.
 */
public abstract class MultiImageFormat : ImageFormat
{
    private static MultiImageFormat[] _registered = [];

    /**
     * Base constructor for the [MultiImageFormat] class.
     */
    @nogc @safe public pure this() nothrow
    {
    }

    /// Always `true`.
    @nogc @property @safe public final override pure bool multi() const nothrow
    out (result; result)
    {
        return true;
    }

    @safe private static MultiImageFormat defaultFormat(const ubyte[] head) nothrow
    {
        if (head[0 .. 4] == [0, 0, 1, 0] || head[0 .. 4] == [0, 0, 2, 0])
        {
            return IcoFormat.instance();
        }
        return null;
    }

    /**
     * Attempts to find the correct multi-image format for a file.
     *
     * Params:
     *     head =
     *         The beginning of the file.
     *         This should be the first 16 bytes of the file if the file is at least 16 bytes long and the while file if it isn't.
     *
     * Returns:
     *         The found multi-image format, if any, `null` otherwise.
     */
    public static MultiImageFormat format(const ubyte[] head)
    {
        foreach (MultiImageFormat f; _registered)
        {
            if (f.checkFormat(head))
            {
                return f;
            }
        }
        return defaultFormat(head);
    }

    /**
     * Attempts to find the correct multi-image format for the given file.
     * The position of the given file pointer is reset to its original position after use.
     * Registered user-defined formats are prioritized over default formats.
     *
     * Params:
     *     fp =
     *         The file pointer to be used.
     *         It must be open for binary read.
     *         It must point to the beginning of the image file, which may be part of a larger file.
     *         Any data preceding the file pointer is ignored.
     *
     * Returns:
     *         The found multi-image format, if any, `null` otherwise.
     */
    public static MultiImageFormat format(ref File fp)
    {
        ubyte[16] bytes;
        ubyte[] head = fp.rawRead(bytes[]);
        fp.seek(-(cast(int) head.length), SEEK_CUR);
        return format(head);
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
     *         There must be at least one image and no null values.
     */
    public void save(R)(ref File fp, const R bitmaps) const 
            if (!is(R == Bitmap[]) && isIterable!R && !isInfinite!R && is(ForeachType!R == Bitmap))
    in
    {
        assert(bitmaps.length > 0);
    }
    do
    {
        this.save(fp, array(bitmaps));
    }

    /// ditto
    public abstract void save(ref File fp, const Bitmap[] bitmaps) const
    in
    {
        assert(bitmaps != null);
        assert(bitmaps.length > 0);
        assert(all!(bmp => bmp !is null)(bitmaps));
    }
}

/**
 * Represents a file format which stores a frame-based animation.
 */
public abstract class AnimatedImageFormat : ImageFormat
{
    private static AnimatedImageFormat[] _registered = [];

    /**
     * Base constructor for the [AnimatedImageFormat] class.
     */
    @nogc @safe public pure this() nothrow
    {
    }

    /// Always `true`.
    @nogc @property @safe public final override pure bool multi() const nothrow
    out (result; result)
    {
        return true;
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
    public abstract override AnimatedImageLoader loader(ref File fp) const;

    @safe private static AnimatedImageFormat defaultFormat(const ubyte[] head) nothrow
    {
        if (head[0 .. 8] == pngSignature)
        {
            return ApngFormat.instance();
        }
        return null;
    }

    /**
     * Attempts to find the correct animated-image format for a file.
     *
     * Params:
     *     head =
     *         The beginning of the file.
     *         This should be the first 16 bytes of the file if the file is at least 16 bytes long and the while file if it isn't.
     *
     * Returns:
     *         The found animated-image format, if any, `null` otherwise.
     */
    public static AnimatedImageFormat format(const ubyte[] head)
    {
        foreach (AnimatedImageFormat f; _registered)
        {
            if (f.checkFormat(head))
            {
                return f;
            }
        }
        return defaultFormat(head);
    }

    /**
     * Attempts to find the correct animated-image format for the given file.
     * The position of the given file pointer is reset to its original position after use.
     * Registered user-defined formats are prioritized over default formats.
     *
     * Params:
     *     fp =
     *         The file pointer to be used.
     *         It must be open for binary read.
     *         It must point to the beginning of the image file, which may be part of a larger file.
     *         Any data preceding the file pointer is ignored.
     *
     * Returns:
     *         The found animated-image format, if any, `null` otherwise.
     */
    public static AnimatedImageFormat format(ref File fp)
    {
        ubyte[16] bytes;
        ubyte[] head = fp.rawRead(bytes[]);
        fp.seek(-(cast(int) head.length), SEEK_CUR);
        return format(head);
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
     *     animation =
     *         The animation to be exported.
     *         It cannot be null.
     */
    public abstract void save(ref File fp, const Animation animation) const
    in (animation !is null);
}

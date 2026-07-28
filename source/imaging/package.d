/**
 * This is a library for representing and managing basic raster RGBA images in D as rectangular arrays of pixels.
 * It is written in pure D with no external dependencies (other than the standard library).
 *
 * The goal of this library is to provide a simple, yet versatile, shared representation for, effectively, the most common kind of image in computing, so other libraries may leech upon it, building compatibility and making it a *lingua franca* for images in D, ideal for writing ***glue code***, including with other languages.
 * It aims at supporting other libraries, not replacing them.
 *
 * Images are represented in row-wise pixel order, either top to bottom (the default) or bottom to top, with each scan line going left to right.
 * Color components are represented as 8-bit integral values ranging between, and including, 0 and 255.
 * Multiple pixel formats are supported.
 *
 * This library doesn't provide any support for other color models, for high dynamic ranges or higher bit depths, for advanced manipulation or for GPU processing.
 * None is planned.
 * Features that should belong to more specific libraries, rather than to one serving as a basis for others, are out of scope.
 *
 * Copyright: Copyright (C) 2026 Valentino Giudice
 * License: BSL-1.0
 * Authors: Valentino Giudice, https://www.functorfault.net/
 */
module imaging;

import std.algorithm.comparison : among;
import std.algorithm.iteration : sum;
import std.algorithm.mutation : reverse, swap, swapRanges;
import std.algorithm.searching : all, canFind, minIndex;
import std.bitmanip : swapEndian;
import std.exception : assumeWontThrow, enforce;
import std.math.algebraic : sqrt;
import std.math.exponential : pow;
import std.range : iota;
import std.range.primitives : isRandomAccessRange;
import std.system : Endian, endian;

/**
 * Specifies the format of the pixel data for an image.
 *
 * The documentation matches the provided pixel formats to those in [Cairo](https://www.cairographics.org/), [stb_image](https://github.com/nothings/stb/blob/master/stb_image.h), [Skia](https://skia.org/), Java [Abstract Window Toolkit](https://docs.oracle.com/javase/docs/technotes/guides/awt/index.html) and [.NET](https://dotnet.microsoft.com/).
 */
public enum PixelFormat
{
    /// Specifies that the format is 1 bit per pixel, indexed.
    /// The color table has at most 2 colors in it.
    /// Leftmost pixels use the most significant bits.
    /// Same as [`System.Imaging.Imaging.PixelFormat.Format1bppIndexed`](https://learn.microsoft.com/dotnet/api/system.imaging.imaging.pixelformat) in .NET.
    Format1bppIndexed,

    /// Specifies that the format is 4 bits per pixel, indexed.
    /// The color table has at most 16 colors in it.
    /// Leftmost pixels use the most significant bits.
    /// Same as [`System.Imaging.Imaging.PixelFormat.Format4bppIndexed`](https://learn.microsoft.com/dotnet/api/system.imaging.imaging.pixelformat) in .NET.
    Format4bppIndexed,

    /// Specifies that the format is 8 bits per pixel, indexed.
    /// The color table has at most 256 colors in it.
    /// Same as [java.awt.image.BufferedImage.TYPE_BYTE_INDEXED](https://docs.oracle.com/javase/8/docs/api/java/awt/image/BufferedImage.html#TYPE_BYTE_INDEXED) in Java AWT.
    /// Same as [`System.Imaging.Imaging.PixelFormat.Format8bppIndexed`](https://learn.microsoft.com/dotnet/api/system.imaging.imaging.pixelformat) in .NET.
    Format8bppIndexed,

    /// Specifies that the format is 8 bits per pixel and represents grayscale colors.
    /// Same as `STBI_grey` in stb_image.
    /// Same as [`SkColorType::kGray_8_SkColorType`](https://api.skia.org/SkColorType_8h.html#a3ea8ab47612dbc4801c18445176c6481a78e84273a803c16991878f27978817fd) in Skia.
    /// Same as [java.awt.image.BufferedImage.TYPE_BYTE_GRAY](https://docs.oracle.com/javase/8/docs/api/java/awt/image/BufferedImage.html#TYPE_BYTE_GRAY) in Java AWT.
    Format8bppGray,

    /// Specifies that the format is 16 bits per pixel, in big endian byte order, where 5 bits each are used for the red, green and blue components and the most significant bit is not used.
    /// Same as [Format16bppRgb555] on big-endian architectures.
    Format16bppRgb555BE,

    /// Specifies that the format is 16 bits per pixel, in little endian byte order, where 5 bits each are used for the red, green and blue components and the most significant bit is not used.
    /// Same as [Format16bppRgb555] on little-endian architectures.
    Format16bppRgb555LE,

    /// Specifies that the format is 16 bits per pixel, in big endian byte order, where 5 bits are used for the red component, 6 bits are used for the green component and 5 bits are used for the blue component.
    /// Same as [Format16bppRgb565] on big-endian architectures.
    Format16bppRgb565BE,

    /// Specifies that the format is 16 bits per pixel, in little endian byte order, where 5 bits are used for the red component, 6 bits are used for the green component and 5 bits are used for the blue component.
    /// Same as [Format16bppRgb565] on little-endian architectures.
    Format16bppRgb565LE,

    /// Specifies that the format is 24 bits per pixel, in big endian order, where 8 bits each are used for the red, green, and blue components.
    /// Red and blue are, respectively, the first and last component of each triplet.
    /// Same as [Format24bppRgb] on big-endian architectures.
    /// Same as `STBI_rgb` in stb_image.
    /// Same as [`SkColorType::kRGB_888x_SkColorType`](https://api.skia.org/SkColorType_8h.html#a3ea8ab47612dbc4801c18445176c6481aad968b8e1db8edd8197175a33563d72d) in Skia.
    Format24bppRgbBE,

    /// Specifies that the format is 24 bits per pixel, in little endian order, where 8 bits each are used for the red, green, and blue components.
    /// Blue and red are, respectively, the first and last component of each triplet.
    /// Same as [Format24bppRgb] on little-endian architectures.
    /// Same as [`SkColorType::kRGB_888x_SkColorType`](https://api.skia.org/SkColorType_8h.html#a3ea8ab47612dbc4801c18445176c6481aad968b8e1db8edd8197175a33563d72d) in Skia.
    /// Same as [java.awt.image.BufferedImage.TYPE_3BYTE_BGR](https://docs.oracle.com/javase/8/docs/api/java/awt/image/BufferedImage.html#TYPE_3BYTE_BGR) in Java AWT.
    Format24bppRgbLE,

    /// Specifies that the format is 32 bits per pixel, in big endian order, where 8 bits are unused and the remaining bytes are used for the red, green, and blue components.
    /// Same as [Format32bppXrgb] on big-endian architectures.
    Format32bppXrgbBE,

    /// Specifies that the format is 32 bits per pixel, in little endian order, where 8 bits are unused and the remaining bytes are used for the red, green, and blue components.
    /// Same as [Format32bppXrgb] on little-endian architectures.
    Format32bppXrgbLE,

    /// Specifies that the format is 32 bits per pixel, in big endian order, where 8 bits each are used for the alpha, red, green, and blue components.
    /// Same as [Format32bppArgb] on big-endian architectures.
    Format32bppArgbBE,

    /// Specifies that the format is 32 bits per pixel, in little endian order, where 8 bits each are used for the alpha, red, green, and blue components.
    /// Same as [Format32bppArgb] on little-endian architectures.
    /// Same as [`SkColorType::kBGRA_8888_SkColorType`](https://api.skia.org/SkColorType_8h.html#a3ea8ab47612dbc4801c18445176c6481a31d85e3857add0465519d7422438372f) in Skia.
    Format32bppArgbLE,

    /// Specifies that the format is 32 bits per pixel, in big endian order, where 8 bits each are used for the red, green, blue and alpha components.
    /// Same as [Format32bppRgba] on big-endian architectures.
    /// Same as `STBI_rgb_alpha` in stb_image.
    /// Same as [`SkColorType::kRGBA_8888_SkColorType`](https://api.skia.org/SkColorType_8h.html#a3ea8ab47612dbc4801c18445176c6481aa880f4868f47bcff4139a6d630b2a0ff) in Skia.
    Format32bppRgbaBE,

    /// Specifies that the format is 32 bits per pixel, in little endian order, where 8 bits each are used for the red, green, blue and alpha components.
    /// Same as [Format32bppRgba] on little-endian architectures.
    /// Same as [java.awt.image.BufferedImage.TYPE_4BYTE_ABGR](https://docs.oracle.com/javase/8/docs/api/java/awt/image/BufferedImage.html#TYPE_4BYTE_ABGR) in Java AWT.
    Format32bppRgbaLE,

    /// Specifies that the format is 16 bits per pixel, where 5 bits each are used for the red, green and blue components and the most significant bit is not used.
    /// Same as [Format16bppRgb555BE] on big-endian architectures and as [Format16bppRgb555LE] on little-endian architectures.
    /// Same as [java.awt.image.BufferedImage.TYPE_USHORT_555_RGB](https://docs.oracle.com/javase/8/docs/api/java/awt/image/BufferedImage.html#TYPE_USHORT_555_RGB) in Java AWT.
    /// Same as [`System.Imaging.Imaging.PixelFormat.Format16bppRgb555`](https://learn.microsoft.com/dotnet/api/system.imaging.imaging.pixelformat) in .NET.
    Format16bppRgb555 = (endian == Endian.bigEndian ? Format16bppRgb555BE
            : Format16bppRgb555LE),

    /// Specifies that the format is 16 bits per pixel, where 5 bits are used for the red component, 6 bits are used for the green component and 5 bits are used for the blue component.
    /// Same as [Format16bppRgb565BE] on big-endian architectures and as [Format16bppRgb565LE] on little-endian architectures.
    /// Same as [java.awt.image.BufferedImage.TYPE_USHORT_565_RGB](https://docs.oracle.com/javase/8/docs/api/java/awt/image/BufferedImage.html#TYPE_USHORT_565_RGB) in Java AWT.
    /// Same as [`System.Imaging.Imaging.PixelFormat.Format16bppRgb565`](https://learn.microsoft.com/dotnet/api/system.imaging.imaging.pixelformat) in .NET.
    Format16bppRgb565 = (endian == Endian.bigEndian ? Format16bppRgb565BE
            : Format16bppRgb565LE),

    /// Specifies that the format is 24 bits per pixel, where 8 bits each are used for the red, green, and blue components.
    /// Same as [Format24bppRgbBE] on big-endian architectures and as [Format24bppRgbLE] on little-endian architectures.
    /// Same as [`System.Imaging.Imaging.PixelFormat.Format24bppRgb`](https://learn.microsoft.com/dotnet/api/system.imaging.imaging.pixelformat) in .NET.
    Format24bppRgb = (endian == Endian.bigEndian ? Format24bppRgbBE
            : Format24bppRgbLE),

    /// Specifies that the format is 32 bits per pixel, where 8 bits are unused and the remaining bytes are used for the red, green, and blue components.
    /// Same as [Format32bppXrgbBE] on big-endian architectures and as [Format32bppXrgbLE] on little-endian architectures.
    /// Same as [`CAIRO_FORMAT_RGB24`](https://www.cairographics.org/manual-1.0.2/cairo-Image-Surfaces.html#cairo-format-t) in Cairo.
    /// Same as [java.awt.image.BufferedImage.TYPE_INT_RGB](https://docs.oracle.com/javase/8/docs/api/java/awt/image/BufferedImage.html#TYPE_INT_RGB) in Java AWT.
    Format32bppXrgb = (endian == Endian.bigEndian ? Format32bppXrgbBE
            : Format32bppXrgbLE),

    /// Specifies that the format is 32 bits per pixel, where 8 bits each are used for the alpha, red, green, and blue components.
    /// Same as [Format32bppArgbBE] on big-endian architectures and as [Format32bppArgbLE] on little-endian architectures.
    /// Same as [java.awt.image.BufferedImage.TYPE_INT_ARGB](https://docs.oracle.com/javase/8/docs/api/java/awt/image/BufferedImage.html#TYPE_INT_ARGB) in Java AWT (its default color model).
    /// Same as [`System.Imaging.Imaging.PixelFormat.Format32bppArgb`](https://learn.microsoft.com/dotnet/api/system.imaging.imaging.pixelformat) in .NET.
    Format32bppArgb = (endian == Endian.bigEndian ? Format32bppArgbBE
            : Format32bppArgbLE),

    /// Specifies that the format is 32 bits per pixel, where 8 bits each are used for the red, green, blue and alpha components.
    /// Same as [Format32bppRgbaBE] on big-endian architectures and as [Format32bppRgbaLE] on little-endian architectures.
    /// Same as [`CAIRO_FORMAT_ARGB32`](https://www.cairographics.org/manual-1.0.2/cairo-Image-Surfaces.html#cairo-format-t) in Cairo.
    /// Same as [`System.Imaging.Imaging.PixelFormat.Format32bppRgba`](https://learn.microsoft.com/dotnet/api/system.imaging.imaging.pixelformat) in .NET.
    Format32bppRgba = (endian == Endian.bigEndian
            ? Format32bppRgbaBE : Format32bppRgbaLE)
}

/// Whether pixel data in the given pixel format contains color-indexed values, with reference to a color table, as opposed to individual color values.
@nogc @safe public pure bool indexed(PixelFormat pixelFormat) nothrow
{
    switch (pixelFormat)
    {
    case PixelFormat.Format1bppIndexed, PixelFormat.Format4bppIndexed,
            PixelFormat.Format8bppIndexed:
            return true;
    default:
        return false;
    }
}

/// The number of bits per pixel in the given pixel format.
/// Always a divsior or multiple of 8.
@nogc @safe public pure int bpp(PixelFormat pixelFormat) nothrow
{
    final switch (pixelFormat)
    {
    case PixelFormat.Format1bppIndexed:
        return 1;
    case PixelFormat.Format4bppIndexed:
        return 4;
    case PixelFormat.Format8bppIndexed, PixelFormat.Format8bppGray:
        return 8;
    case PixelFormat.Format16bppRgb555BE, PixelFormat.Format16bppRgb555LE,
            PixelFormat.Format16bppRgb565BE, PixelFormat.Format16bppRgb565LE:
            return 16;
    case PixelFormat.Format24bppRgbBE, PixelFormat.Format24bppRgbLE:
        return 24;
    case PixelFormat.Format32bppXrgbBE, PixelFormat.Format32bppXrgbLE, PixelFormat.Format32bppArgbBE,
            PixelFormat.Format32bppArgbLE, PixelFormat.Format32bppRgbaBE,
            PixelFormat.Format32bppRgbaLE:
            return 32;
    }
}

/// The alignment size for pixel data for the given format, in bytes.
@nogc @safe public pure int alignSize(PixelFormat pixelFormat) nothrow
{
    final switch (bpp(pixelFormat))
    {
    case 1, 4:
        return 1;
    case 8:
        return 1;
    case 16:
        return ushort.alignof;
    case 24:
        return 1;
    case 32:
        return uint.alignof;
    }
}

/**
 * Returns the pixel format which corresponds to the given one with reverse byte order.
 *
 * Params:
 *     pixelFormat =
 *         The pixel format whose endianess is to be swapped.
 *
 * Returns:
 *     The pixel format which corresponds to the given one with reverse byte order.
 *     This is the same as the input pixel format if it has no more than 8 bits per pixel.
 */
@nogc @safe public pure PixelFormat flipEndian(PixelFormat pixelFormat) nothrow
{
    if (pixelFormat.bpp <= 8)
    {
        return pixelFormat;
    }
    static assert(PixelFormat.Format16bppRgb555BE % 2 == 0);
    if (pixelFormat % 2 == 0)
    {
        return cast(PixelFormat)(pixelFormat + 1);
    }
    return cast(PixelFormat)(pixelFormat - 1);
}

/**
 * Represents a RGBA (red, green, blue, alpha) color.
 *
 * Each channel is represented as an unsigned byte.
 * Color channels specify the intensity for their respective color components, with 0 indicating no intensity and 255 indicating full intensity.
 * The alpha channel specifies the opacity of the color, with 0 indicating full transparency and 255 indicating full opacity.
 * The four values are packed as an unsigned 32-bits integer, where the red channel occupies the most significant byte and the alpha channel occupies the least significant byte.
 * This representation corresponds to the [PixelFormat.Format32bppRgba] pixel format.
 */
@safe public union Color
{
    /// The red, green, blue and alpha component values of this color packed as a 32-bit unsigned integer, where red occupies the least significant byte and alpha the most significant byte, in accordance with the [PixelFormat.Format32bppRgba] pixel format.
    uint rgba;

    version (BigEndian)
    {
        struct
        {
            /// The red component value of this color.
            ubyte r;

            /// The green component value of this color.
            ubyte g;

            /// The blue component value of this color.
            ubyte b;

            /// The alpha component value of this color.
            ubyte a;
        }
    }
    else version (LittleEndian)
    {
        struct
        {
            /// The alpha component value of this color.
            ubyte a;

            /// The blue component value of this color.
            ubyte b;

            /// The green component value of this color.
            ubyte g;

            /// The red component value of this color.
            ubyte r;
        }
    }
    else
    {
        static assert(0);
    }

    /**
     * Creates a [Color] object with the given red, green, blue and alpha values packed as a 32-byte unsigned integer.
     *
     * Params:
     *     rgba = The red, green, blue and alpha component values of this color packed as a 32-bit unsigned integer, where red occupies the least significant byte and alpha the most significant byte, in accordance with the [PixelFormat.Format32bppRgba] pixel format.
     */
    @nogc public pure this(uint rgba) nothrow
    {
        this.rgba = rgba;
    }

    /**
     * Creates a [Color] object with the given red, green, blue and alpha values.
     *
     * Params:
     *     r = The red component value for the color.
     *     g = The green component value for the color.
     *     b = The blue component value for the color.
     *     a = The alpha component value for the color.
     */
    @nogc public pure this(ubyte r, ubyte g, ubyte b, ubyte a) nothrow
    {
        this.r = r;
        this.g = g;
        this.b = b;
        this.a = a;
    }

    /**
     * Creates a [Color] object representing a fully opaque color with the given red, green and blue.
     *
     * Params:
     *     r = The red component value for the color.
     *     g = The green component value for the color.
     *     b = The blue component value for the color.
     */
    @nogc public pure this(ubyte r, ubyte g, ubyte b) nothrow
    {
        this(r, g, b, 0xFF);
    }

    /// Fully opaque `#FF0000` color.
    public static immutable Color red = Color(0xFF, 0, 0);

    /// Fully opaque `#00FF00` color.
    public static immutable Color green = Color(0, 0xFF, 0);

    /// Fully opaque `#0000FF` color.
    public static immutable Color blue = Color(0, 0, 0xFF);

    /// Fully opaque `#00FFFF` color.
    public static immutable Color cyan = Color(0, 0xFF, 0xFF);

    /// Fully opaque `#FF00FF` color.
    public static immutable Color magenta = Color(0xFF, 0, 0xFF);

    /// Fully opaque `#FFFF00` color.
    public static immutable Color yellow = Color(0xFF, 0xFF, 0);

    /// Fully opaque `#000000` color.
    public static immutable Color black = Color(0, 0, 0);

    /// Fully opaque `#FFFFFF` color.
    public static immutable Color white = Color(0xFF, 0xFF, 0xFF);

    /// Martian color associated by GitHub to the D programming language: a fully opaque `#BA595E` color.
    public static immutable Color d = Color(0xBA, 0x59, 0x5E, 0xFF);

    /**
     * Creates a [Color] object representing a fully opaque grayscale color.
     *
     * Params:
     *     luma =
     *         The luma, intensity or brightness of the color.
     *         0 produces black and 255 produces white.
     *
     * Returns: The fully opaque gray color with the given luma value for all color components.
     */
    @nogc public static pure Color gray(ubyte luma) nothrow
    {
        return Color(luma, luma, luma);
    }

    /**
     * Computes the luma of this color, which is a measure of its percieved brightness.
     *
     * Returns:
     *     The computed luma.
     *     For black it is 0 and for white it is 255.
     */
    @nogc public pure ubyte luma() const nothrow
    {
        return ((this.r * 299 + this.g * 587 + this.b * 114) + 500) / 1000;
    }

    // See: https://www.compuphase.com/cmetric.htm
    @nogc private static pure int redmeanDistSquared(ubyte r1, ubyte g1, ubyte b1,
            ubyte r2, ubyte g2, ubyte b2) nothrow
    {
        int rmean = ((cast(int) r1) + r2) / 2;
        int r = (cast(int) r1) - r2;
        int g = (cast(int) g1) - g2;
        int b = (cast(int) b1) - b2;
        return (((512 + rmean) * r * r) >> 8) + 4 * g * g + (((767 - rmean) * b * b) >> 8);
    }

    /**
     * Computes the squared color difference between this and the given color.
     *
     * Returns:
     *     The computed squared color difference.
     *     Always 0 for two identical colors, as well as for two fully transparent colors.
     *     When both colors are fully opaque, the squared redmean distance is returned.
     */
    @nogc public pure int distSquared(Color other) const nothrow
    {
        if (this.a == 0xFF && other.a == 0xFF)
        {
            return redmeanDistSquared(this.r, this.g, this.b, other.r, other.g, other.b);
        }
        ubyte r1 = (this.r * this.a + 0xFF / 2) / 0xFF;
        ubyte g1 = (this.g * this.a + 0xFF / 2) / 0xFF;
        ubyte b1 = (this.b * this.a + 0xFF / 2) / 0xFF;
        ubyte r2 = (other.r * other.a + 0xFF / 2) / 0xFF;
        ubyte g2 = (other.g * other.a + 0xFF / 2) / 0xFF;
        ubyte b2 = (other.b * other.a + 0xFF / 2) / 0xFF;
        int blackDistSquared = redmeanDistSquared(r1, g1, b1, r2, g2, b2);
        ubyte w1 = 0xFF - this.a;
        r1 += w1;
        g1 += w1;
        b1 += w1;
        ubyte w2 = 0xFF - other.a;
        r2 += w2;
        g2 += w2;
        b2 += w2;
        int whiteDistSquared = redmeanDistSquared(r1, g1, b1, r2, g2, b2);
        return (blackDistSquared + whiteDistSquared) / 2;
    }

    /**
     * Computes the color difference between this and the given color.
     *
     * Returns:
     *     The computed color difference.
     *     Always 0 for two identical colors, as well as for two fully transparent colors.
     *     The redmean distance between the two colors if both are fully opaque.
     */
    @nogc public pure float dist(Color other) const nothrow
    {
        int squared = this.distSquared(other);
        return sqrt(cast(float) squared);
    }
}

static assert(Color.alignof == int.alignof);

/**
 * Alpha-blends the given background color and foreground color.
 *
 * Params:
 *     back = The background color.
 *     front = The foreground color.
 *
 * Returns: The alpha-blended color.
 */
@nogc @safe public pure Color blend(Color back, Color front) nothrow
{
    if (front.a == 0)
    {
        return back;
    }
    if (front.a == 255)
    {
        return front;
    }
    float br = back.r / 255.0F;
    float bg = back.g / 255.0F;
    float bb = back.g / 255.0F;
    float ba = back.a / 255.0F;
    float fr = front.r / 255.0F;
    float fg = front.g / 255.0F;
    float fb = front.g / 255.0F;
    float fa = front.a / 255.0F;
    float recA = 1 - fa;
    float a = fa + ba * recA;
    float r = pow((pow(fr, 2.2) * fa + ba * pow(br, 2.2) * recA) / a, 1 / 2.2F);
    float g = pow((pow(fg, 2.2) * fa + ba * pow(bg, 2.2) * recA) / a, 1 / 2.2F);
    float b = pow((pow(fb, 2.2) * fa + ba * pow(bb, 2.2) * recA) / a, 1 / 2.2F);
    ubyte rr = cast(ubyte)(r * 255 + 0.5F);
    ubyte rg = cast(ubyte)(g * 255 + 0.5F);
    ubyte rb = cast(ubyte)(b * 255 + 0.5F);
    ubyte ra = cast(ubyte)(a * 255 + 0.5F);
    return Color(rr, rg, rb, ra);
}

/**
 * Mixes the given color.
 *
 * Params:
 *     color1 = One color to be mixed.
 *     color2 = The other color to be mixed.
 *     factor =
 *         The factor to be used for mixing, between and including 0 and 1.
 *         If it is 0, [color1] is returned.
 *         If it is 1, [color2] is returned.
 *         If it is 0.5, the order of [color1] and [color2] is irrelevant.
 *
 * Returns:
 *     A mix of the two input colors.
 */
@nogc @safe public pure Color mix(Color color1, Color color2, float factor = 0.5F) nothrow
in (0 <= factor && factor <= 1)
{
    if (factor == 0)
    {
        return color1;
    }
    if (factor == 1)
    {
        return color2;
    }
    float r1 = color1.r / 255.0F;
    float g1 = color1.g / 255.0F;
    float b1 = color1.b / 255.0F;
    float a1 = color1.a / 255.0F;
    float r2 = color2.r / 255.0F;
    float g2 = color2.g / 255.0F;
    float b2 = color2.b / 255.0F;
    float a2 = color2.a / 255.0F;
    float f1;
    float f2;
    if (color1.a == 0 && color2.a == 0)
    {
        f1 = 1 - factor;
        f2 = factor;
    }
    else
    {
        f1 = a1 * (1 - factor);
        f2 = a2 * factor;
    }
    float a = f1 + f2;
    float r = pow(pow(r1, 2.2F) * f1 + pow(r2, 2.2F) * f2, 1 / 2.2F) / a;
    float g = pow(pow(g1, 2.2F) * f1 + pow(g2, 2.2F) * f2, 1 / 2.2F) / a;
    float b = pow(pow(b1, 2.2F) * f1 + pow(b2, 2.2F) * f2, 1 / 2.2F) / a;
    if (color1.a == 0 && color2.a == 0)
    {
        a = 0;
    }
    ubyte rr = cast(ubyte)(r * 255 + 0.5F);
    ubyte rg = cast(ubyte)(g * 255 + 0.5F);
    ubyte rb = cast(ubyte)(b * 255 + 0.5F);
    ubyte ra = cast(ubyte)(a * 255 + 0.5F);
    return Color(rr, rg, rb, ra);
}

/**
 * Represents an axes-aligned rectangle.
 */
public struct Rectangle
{
    /// The X coordinate of the leftmost column of the rectangle.
    int x;

    /// The minimum Y coordinate of the rectangle, either that of its top or its bottom row.
    int y;

    /// The width of the rectangle.
    int width;

    /// The height of the rectangle.
    int height;
}

/**
 * Represents a generic image with the given pixel color type.
 *
 * Params:
 *     T = The type representing pixel colors.
 */
public interface Image(T)
{
    /// The width of the image, in pixels.
    @nogc @safe @property pure int width() const nothrow
    out (result; result > 0);

    /// The height of the image, in pixels.
    @nogc @safe @property pure int height() const nothrow
    out (result; result > 0);

    /**
     * Gets the color of the specified pixel in this image.
     *
     * Params:
     *     x = The X coordinate of the pixel in the image.
     *     y = The Y coordinate of the pixel in the image.
     */
    @safe T getPixel(int x, int y) const
    in
    {
        assert(0 <= x && x < this.width);
        assert(0 <= y && y < this.height);
    }

    /**
     * Sets the color of the specified pixel in this image.
     *
     * Params:
     *     x = The X coordinate of the pixel in the image.
     *     y = the Y coordinate of the pixel in the image.
     *     color = The color to be set for the pixel.
     */
    @safe void setPixel(int x, int y, T color)
    in
    {
        assert(0 <= x && x < this.width);
        assert(0 <= y && y < this.height);
    }
}

@nogc private ubyte to5bits(ubyte val) nothrow
{
    ubyte val1 = val >> 3;
    if (val < 64)
    {
        val1 |= 0b00001 & val >> 2;
    }
    else if (64 < val && val < 96)
    {
        val1 |= 0b00001 & (val >> 2 & val >> 1);
    }
    else if (96 < val && val < 112)
    {
        val1 |= 0b00001 & (val >> 2 & val >> 1 & val);
    }
    else if (144 < val && val < 160)
    {
        val1 &= 0b11110 | (val >> 2 | val >> 1 | val);
    }
    else if (160 < val && val < 192)
    {
        val1 &= 0b11110 | (val >> 2 | val >> 1);
    }
    else if (192 < val)
    {
        val1 &= 0b11110 | val >> 2;
    }
    return val1;
}

@nogc private ubyte to6bits(ubyte val) nothrow
{
    ubyte val1 = val >> 2;
    if (val < 64)
    {
        val1 |= 0b00001 & val >> 1;
    }
    else if (64 < val && val < 96)
    {
        val1 |= 0b00001 & (val >> 1 & val);
    }
    else if (144 < val && val < 192)
    {
        val1 &= 0b11110 | (val >> 1 | val);
    }
    else if (192 < val)
    {
        val1 &= 0b11110 | val >> 1;
    }
    return val1;
}

@nogc private static void copyBitsBuffer(ubyte* dest, size_t destOffset,
        const(ubyte)* src, size_t srcOffset, size_t length) nothrow
{
    if (length == 0)
    {
        return;
    }
    dest += destOffset / 8;
    destOffset %= 8;
    src += srcOffset / 8;
    srcOffset %= 8;
    if (length <= 8)
    {
        for (int i = 0; i < length; i++)
        {
            ubyte val = cast(ubyte)(((src[(srcOffset + i) / 8] >> (7 - (srcOffset + i) % 8)) & 1) << (
                    7 - (destOffset + i) % 8));
            dest[(destOffset + i) / 8] = (dest[(destOffset + i) / 8] & ~(
                    1 << (7 - (destOffset + i) % 8))) | val;
        }
    }
    int bits = (length - 8 + destOffset) % 8;
    size_t bytes = (length - 8 + destOffset) / 8;
    if (srcOffset == destOffset)
    {
        int leftBits = srcOffset % 8;
        size_t middleBytes = (length - leftBits) / 8;
        int rightBits = (length - leftBits) % 8;
        if (leftBits > 0)
        {
            ubyte val = src[0] & 0xFF >> (8 - leftBits);
            dest[0] = dest[0] & 0xFF << leftBits | val;
        }
        if (middleBytes > 0)
        {
            dest[!!leftBits .. !!leftBits + middleBytes] = src[!!leftBits
                .. !!leftBits + middleBytes];
        }
        if (rightBits > 0)
        {
            ubyte val = src[!!leftBits + middleBytes] & 0xFF << (8 - rightBits);
            dest[!!leftBits + middleBytes] = dest[!!leftBits + middleBytes] & 0xFF >> rightBits
                | val;
        }
    }
    else if (srcOffset > destOffset)
    {
        size_t shift = srcOffset - destOffset;
        dest[0] = (dest[0] & 0xFF << (8 - destOffset)) | (
                0xFF >> destOffset & (src[0] << shift | src[1] >> (8 - shift)));
        for (int i = 1; i <= bytes; i++)
        {
            dest[i] = cast(ubyte)(src[i] << shift | src[i + 1] >> (8 - shift));
        }
        if (bits > 0)
        {
            ubyte val = cast(ubyte)(src[bytes + 1] << shift);
            if (bits > 8 - shift)
            {
                val |= src[bytes + 2] >> (8 - shift);
            }
            dest[bytes + 1] = cast(ubyte)((0xFF << (8 - bits) & val) | (dest[bytes + 1] & 0xFF
                    >> bits));
        }
    }
    else
    {
        size_t shift = destOffset - srcOffset;
        dest[0] = (dest[0] & 0xFF << (8 - destOffset)) | (0xFF >> destOffset & src[0] >> shift);
        for (int i = 1; i <= bytes; i++)
        {
            dest[i] = cast(ubyte)(src[i - 1] << (8 - shift) | src[i] >> shift);
        }
        if (bits > 0)
        {
            ubyte val = cast(ubyte)(src[bytes] << (8 - shift));
            if (bits > shift)
            {
                val |= src[bytes + 1] >> shift;
            }
            dest[bytes + 1] = cast(ubyte)((0xFF << (8 - bits) & val) | (dest[bytes + 1] & 0xFF
                    >> bits));
        }
    }
}

private static void flipBits(ubyte* buffer, size_t offset, size_t length, bool[] bits = null)
{
    buffer += offset / 8;
    offset %= 8;
    size_t bytes = (offset + length + 7) / 8;
    if (bits == null)
    {
        bits = new bool[bytes * 8];
    }
    for (size_t i = 0; i < bytes; i++)
    {
        for (int j = 0; j < 8; j++)
        {
            bits[i * 8 + j] = buffer[i] >> (7 - j) & 1;
        }
    }
    reverse(bits[offset .. offset + length]);
    for (size_t i = 0; i < bytes; i++)
    {
        ubyte val = 0;
        for (int j = 0; j < 8; j++)
        {
            val = cast(ubyte)(val << 1 | bits[i * 8 + j]);
        }
        buffer[i] = val;
    }
}

@nogc private static void fillBitsBuffer(ubyte* buffer, size_t offset, size_t length, bool value) nothrow
{
    if (length == 0)
    {
        return;
    }
    buffer += offset / 8;
    offset %= 8;
    if (length < 8)
    {
        for (int i = 0; i < length; i++)
        {
            if (value)
            {
                buffer[(offset + i) / 8] |= 1 << (7 - (offset + i) % 8);
            }
            else
            {
                buffer[(offset + i) / 8] &= ~(1 << (7 - (offset + i) % 8));
            }
        }
    }
    else
    {
        ubyte bvalue = 0;
        for (int i = 0; i < 8; i++)
        {
            bvalue = cast(ubyte)(bvalue << 1 | value);
        }
        int leftBits = (8 - offset) % 8;
        if (leftBits > 0)
        {
            buffer[0] = (buffer[0] & 0xFF << leftBits) | (bvalue & 0xFF >> (8 - leftBits));
        }
        size_t bytes = (length - leftBits) / 8;
        buffer[leftBits > 0 .. leftBits > 0 + bytes] = bvalue;
        int rightBits = (length - leftBits) & 8;
        if (rightBits > 0)
        {
            buffer[leftBits > 0 + bytes] = (bvalue & 0xFF << (8 - rightBits)) | (
                    buffer[leftBits > 0 + bytes] & 0xFF >> rightBits);
        }
    }
}

// If possible, computes an arithmetically correct ((skipX + width) * pixelFormat.bpp + 7) / 8.
// Using that expression alone may produce incorrect results due to intermediate values exceding the maximum of their type.
// If the final result does not fit in a size_t value, 0 is returned.
@nogc @safe package pure size_t minStride(size_t skipX, int width, int bpp) nothrow
{
    if (bpp < 8)
    {
        size_t stride1 = (skipX >> 3) * bpp;
        if (stride1 % bpp != 0 || stride1 / bpp != (skipX >> 3))
        {
            return 0;
        }
        size_t stride2 = (width >> 3) * bpp;
        if (stride2 % bpp != 0 || stride2 / bpp != (width >> 3))
        {
            return 0;
        }
        int r1 = skipX & 0b111;
        int r2 = width & 0b111;
        int stride3 = ((r1 + r2) * bpp + 7) >> 3;
        if (stride2 > size_t.max - stride1 || stride3 > size_t.max - (stride1 + stride2))
        {
            return 0;
        }
        size_t stride = stride1 + stride2 + stride3;
        return stride;
    }
    int bytesPerPixel = bpp >> 3;
    if (width > size_t.max - skipX)
    {
        return 0;
    }
    size_t values = skipX + width;
    size_t stride = values * bytesPerPixel;
    if (stride % bytesPerPixel != 0 || stride / bytesPerPixel != values)
    {
        return 0;
    }
    return stride;
}

/**
 * Represent an RGBA image, stored row-wise in one of multiple pixel formats.
 */
@safe public final class Bitmap : Image!Color
{
    private immutable int _width;
    private immutable int _height;
    private immutable size_t _skipX;
    private immutable size_t _stride;
    private immutable PixelFormat _pixelFormat;
    private immutable(Color)[] _palette;
    private bool _bottomUp;
    private ubyte[] _data;

    /**
     * Creates a [Bitmap] object, allocating new pixel data.
     *
     * Params:
     *     width = The width of the image, in pixel. It must be greater than 0.
     *     height = The height of the image, in pixel. It must be greater than 0.
     *     pixelFormat = The format for the pixel data for the image.
     *     palette =
     *         The color table for the image.
     *         For an indexed pixel format, it must have a length between 1 and the maximum for that format.
     *         For a non-indexed format, it must be an empty array, representing the absence of a color table.
     */
    @trusted public this(int width, int height, PixelFormat pixelFormat,
            immutable Color[] palette = null) nothrow
    in
    {
        assert(width > 0 && height > 0);
        if (pixelFormat.indexed)
        {
            assert(palette != null && 1 <= palette.length && palette.length <= 1 << pixelFormat.bpp);
        }
        else
        {
            assert(palette == null);
        }
    }
    out
    {
        assert(this.width == width);
        assert(this.height == height);
        assert(this.skipX == 0);
        size_t mStride = minStride(skipX, width, pixelFormat.bpp);
        assert(mStride != 0 && this.stride == mStride);
        assert(this.pixelFormat == pixelFormat);
        if (pixelFormat.indexed)
        {
            assert(this.palette == palette);
        }
        else
        {
            assert(this.palette.ptr == null && this.palette.length == 0);
        }
    }
    do
    {
        this._width = width;
        this._height = height;
        this._skipX = 0;
        if (pixelFormat.bpp <= 8)
        {
            this._stride = cast(size_t)(((cast(ulong) width) * pixelFormat.bpp + 7) / 8);
            this._data = new ubyte[this._stride * height];
        }
        else if (pixelFormat.bpp == 16)
        {
            this._stride = width * 2;
            this._data = cast(ubyte[]) cast(void[]) new ushort[width * height];
        }
        else if (pixelFormat.bpp == 24)
        {
            this._stride = width * 3;
            this._data = new ubyte[this._stride * height];
        }
        else if (pixelFormat.bpp == 32)
        {
            this._stride = width * 4;
            this._data = cast(ubyte[]) cast(void[]) new uint[width * height];
        }
        this._palette = palette;
        this._bottomUp = false;
        this._pixelFormat = pixelFormat;
    }

    /**
     * Creates a [Bitmap] object with existing pixel data.
     *
     * Params:
     *     width =
     *         The width of the image, in pixel.
     *         It must be greater than 0.
     *     height =
     *         The height of the image, in pixel.
     *         It must be greater than 0.
     *     skipX = The number of values in pixel data to be skipped from the left, in pixel size.
     *     stride =
     *         The distance between corresponding horizontal positions in consecutive rows in pixel data, in bytes.
     *         It must be a multiple of the alignment size of the pixel format.
     *     pixelFormat = The format for the pixel data for the image.
     *     palette =
     *         The color table for the image.
     *         For an indexed pixel format, it must have a length between 1 and the maximum for that format.
     *         For a non-indexed format, it must be an empty array, representing the absence of a color table.
     *     bottomUp =
     *         Whether rows in the image go from bottom to top.
     *         If `false`, the origin of the image is in the top-left corner, the Y coordinate runs from top to bottom and pixel data scans lines from top to bottom.
     *         If `true`, the origin of the image is in the bottom-left corner, the Y coordinate goes from bottom to top and pixel data scans lines from bottom to top.
     *     data =
     *         The actual pixel data.
     *         The array must be aligned to the alignment size of the pixel format.
     *         Its length must be the product between `stride` and `height`.
     */
    @trusted public this(int width, int height, size_t skipX, size_t stride,
            PixelFormat pixelFormat, immutable Color[] palette, bool bottomUp, inout void[] data) inout nothrow
    in
    {
        assert(width > 0 && height > 0);
        size_t mStride = minStride(skipX, width, pixelFormat.bpp);
        assert(mStride != 0 && stride >= mStride);
        assert(data != null);
        assert(data.length % stride == 0 && data.length / stride == height);
        assert((cast(size_t) data.ptr) % pixelFormat.alignSize == 0);
        assert(stride % pixelFormat.alignSize == 0);
        if (pixelFormat.indexed)
        {
            assert(palette != null && 1 <= palette.length && palette.length <= 1 << pixelFormat.bpp);
        }
        else
        {
            assert(palette == null);
        }
    }
    out
    {
        assert(this.width == width);
        assert(this.height == height);
        assert(this.skipX == skipX);
        assert(this.stride == stride);
        assert(this.pixelFormat == pixelFormat);
        if (pixelFormat.indexed)
        {
            assert(this.palette == palette);
        }
        else
        {
            assert(this.palette.ptr == null && this.palette.length == 0);
        }
        assert(this.data is data);
    }
    do
    {
        this._width = width;
        this._height = height;
        this._skipX = skipX;
        this._stride = stride;
        this._bottomUp = bottomUp;
        this._pixelFormat = pixelFormat;
        this._palette = palette;
        this._data = cast(inout ubyte[]) data;
    }

    /// The width of the image, in pixels.
    @nogc @property public pure int width() const nothrow
    {
        return this._width;
    }

    /// The height of the image, in pixels.
    @nogc @property public pure int height() const nothrow
    {
        return this._height;
    }

    /// The number of values in pixel data to be skipped from the left, in pixel size.
    @nogc @property public pure size_t skipX() const nothrow
    {
        return this._skipX;
    }

    /// The distance between corresponding horizontal positions in consecutive rows in pixel data, in bytes.
    @nogc @property public pure size_t stride() const nothrow
    {
        return this._stride;
    }

    /// The format for the pixel data for the image.
    @nogc @property public pure PixelFormat pixelFormat() const nothrow
    {
        return this._pixelFormat;
    }

    /// The color table for the image.
    /// For indexed pixel formats, it must have a length between 1 and the maximum for the format.
    /// For non-indexed formats, there is no color table and only an empty array can be assigned to this property, which always evaluates to a null array.
    @nogc @property public pure immutable(Color[]) palette() const nothrow
    out (result)
    {
        if (this.indexed)
        {
            assert(result != null && 1 <= result.length && result.length <= 1 << this.bpp);
        }
        else
        {
            assert(result.ptr == null && result.length == 0);
        }
    }
    do
    {
        return this._palette;
    }

    /// ditto
    @nogc @property public pure void palette(immutable Color[] palette) nothrow
    in
    {
        if (this.indexed)
        {
            assert(palette != null && 1 <= palette.length && palette.length <= 1 << this.bpp);
        }
        else
        {
            assert(palette == null);
        }
    }
    do
    {
        if (this.indexed)
        {
            this._palette = palette;
        }
        else
        {
            this._palette = null;
        }
    }

    /// Whether rows in the image go from bottom to top.
    /// `false` if the origin of the image is in the top-left corner, the Y coordinate runs from top to bottom and pixel data scans lines from top to bottom.
    /// `true` if the origin of the image is in the bottom-left corner, the Y coordinate goes from bottom to top and pixel data scans lines from bottom to top.
    @nogc @property public pure bool bottomUp() const nothrow
    {
        return this._bottomUp;
    }

    /// ditto
    @nogc @property public pure void bottomUp(bool bottomUp) nothrow
    {
        this._bottomUp = bottomUp;
    }

    /// The pixel data of the image.
    /// Its length is the product between the [stride] and [height] properties.
    /// Values are stored in pixel order (array of structs), according to the pixel format given by the [pixelFormat] property.
    /// Each pixel occupies [bpp] bits and the array is aligned according to the [alignSize] property.
    /// Rows are stored top to bottom, or bottom to top, according to the [bottomU] property and represent scan lines that run left to right.
    /// [skipX] positions, in pixel size, are skipped from the beginning of the array. Pixel data may be shared among different [Bitmap] objects.
    @nogc @property public pure inout(void[]) data() inout nothrow
    {
        return this._data;
    }

    /// The alignment size for pixel data in this image, in bytes, based on its pixel format.
    @nogc @property public pure int alignSize() const nothrow
    {
        return this.pixelFormat.alignSize;
    }

    /// The number of bits per pixel in this image, based on its pixel format.
    @nogc @property public pure int bpp() const nothrow
    {
        return this.pixelFormat.bpp;
    }

    /// Whether, based on its pixel format, pixel data in this image contains color-indexed values, as opposed to individual color values.
    /// If `true`, the [palette] property exposes the color table.
    @nogc @property public pure bool indexed() const nothrow
    {
        return this.pixelFormat.indexed;
    }

    @system private Color readColor(const void* ptr, size_t x) const
    {
        final switch (this.pixelFormat)
        {
        case PixelFormat.Format1bppIndexed:
            bool bit = ((cast(ubyte*) ptr)[x / 8]) >> (7 - x % 8) & 1;
            enforce(bit < this.palette.length);
            return this.palette[bit];
        case PixelFormat.Format4bppIndexed:
            ubyte index = ((cast(ubyte*) ptr)[x / 2]) >> ((1 - x % 2) * 4) & 0xF;
            enforce(index < this.palette.length);
            return this.palette[index];
        case PixelFormat.Format8bppIndexed:
            ubyte index = (cast(ubyte*) ptr)[x];
            enforce(index < this.palette.length);
            return this.palette[index];
        case PixelFormat.Format8bppGray:
            ubyte gray = (cast(ubyte*) ptr)[x];
            return Color(gray, gray, gray);
        case PixelFormat.Format16bppRgb555:
            ushort val = (cast(ushort*) ptr)[x];
            ubyte r = val >> 10 & 0b11111;
            r = cast(ubyte)(r << 3 | r >> 2);
            ubyte g = val >> 5 & 0b11111;
            g = cast(ubyte)(g << 3 | g >> 2);
            ubyte b = val & 0b11111;
            b = cast(ubyte)(b << 3 | b >> 2);
            return Color(r, g, b);
        case PixelFormat.Format16bppRgb565:
            ushort val = (cast(ushort*) ptr)[x];
            ubyte r = val >> 11 & 0b11111;
            r = (r << 3 | r >> 3) & 0xFF;
            ubyte g = val >> 5 & 0b111111;
            g = (g << 2 | g >> 4) & 0xFF;
            ubyte b = val & 0b11111;
            b = (b << 3 | b >> 2) & 0xFF;
            return Color(r, g, b);
        case PixelFormat.Format24bppRgbLE:
            ubyte[3] bgr = (cast(ubyte[3]*) ptr)[x];
            return Color(bgr[2], bgr[1], bgr[0]);
        case PixelFormat.Format24bppRgbBE:
            ubyte[3] rgb = (cast(ubyte[3]*) ptr)[x];
            return Color(rgb[0], rgb[1], rgb[2]);
        case PixelFormat.Format32bppXrgb:
            uint xrgb = (cast(uint*) ptr)[x];
            uint rgba = xrgb << 8 | 0xFF;
            return Color(rgba);
        case PixelFormat.Format32bppArgb:
            uint argb = (cast(uint*) ptr)[x];
            uint rgba = argb << 8 | argb >> 24;
            return Color(rgba);
        case PixelFormat.Format32bppRgba:
            uint rgba = (cast(uint*) ptr)[x];
            return Color(rgba);
        case flipEndian(PixelFormat.Format16bppRgb555):
            ushort val = (cast(ushort*) ptr)[x];
            ubyte r = val >> 2 & 0b11111;
            r = (r << 3 | r >> 2) & 0xFF;
            ubyte g = (val << 3 & 0b11000) | (val >> 13 & 0b00111);
            g = (g << 3 | g >> 2) & 0xFF;
            ubyte b = val >> 8 & 0b11111;
            b = (b << 3 | b >> 2) & 0xFF;
            return Color(r, g, b);
        case flipEndian(PixelFormat.Format16bppRgb565):
            ushort val = (cast(ushort*) ptr)[x];
            ubyte r = val >> 3 & 0b11111;
            r = (r << 3 | r >> 3) & 0xFF;
            ubyte g = val << 3 & 0b111000 | val >> 13 & 0b000111;
            g = (g << 2 | g >> 4) & 0xFF;
            ubyte b = val >> 8 & 0b11111;
            b = (b << 3 | b >> 2) & 0xFF;
            return Color(r, g, b);
        case flipEndian(PixelFormat.Format32bppXrgb):
            uint bgrx = (cast(uint*) ptr)[x];
            ubyte r = bgrx >> 8 & 0xFF;
            ubyte g = bgrx >> 12 & 0xFF;
            ubyte b = bgrx >> 24;
            return Color(r, g, b);
        case flipEndian(PixelFormat.Format32bppArgb):
            uint bgra = (cast(uint*) ptr)[x];
            ubyte a = bgra & 0xFF;
            ubyte r = bgra >> 8 & 0xFF;
            ubyte g = bgra >> 16 & 0xFF;
            ubyte b = bgra >> 24;
            return Color(r, g, b, a);
        case flipEndian(PixelFormat.Format32bppRgba):
            uint abgr = (cast(uint*) ptr)[x];
            ubyte r = abgr & 0xFF;
            ubyte g = abgr >> 8 & 0xFF;
            ubyte b = abgr >> 16 & 0xFF;
            ubyte a = abgr >> 24;
            return Color(r, g, b, a);
        }
    }

    @nogc private static ubyte colorIndex(const Color[] palette, Color color) nothrow
    {
        for (ubyte i = 0; i < palette.length; i++)
        {
            if (palette[i] == color)
            {
                return i;
            }
        }
        return cast(ubyte) minIndex!((a, b) => color.distSquared(a) < color.distSquared(b))(palette);
    }

    @nogc @system private static void writeColor(PixelFormat pixelFormat,
            const Color[] palette, void* ptr, size_t x, Color color) nothrow
    {
        final switch (pixelFormat)
        {
        case PixelFormat.Format1bppIndexed:
            ubyte bit = colorIndex(palette, color);
            if (bit)
            {
                (cast(ubyte*) ptr)[x / 8] |= 1 << (7 - x % 8);
            }
            else
            {
                (cast(ubyte*) ptr)[x / 8] &= ~(1 << (7 - x % 8));
            }
            break;
        case PixelFormat.Format4bppIndexed:
            ubyte index = colorIndex(palette, color);
            ubyte vals = (cast(ubyte*) ptr)[x / 2];
            vals &= ~(1 << ((1 - x % 2) * 4));
            vals |= index << ((1 - x % 2) * 4);
            (cast(ubyte*) ptr)[x / 2] = vals;
            break;
        case PixelFormat.Format8bppIndexed:
            ubyte index = colorIndex(palette, color);
            (cast(ubyte*) ptr)[x] = index;
            break;
        case PixelFormat.Format8bppGray:
            (cast(ubyte*) ptr)[x] = color.luma;
            break;
        case PixelFormat.Format16bppRgb555:
            ubyte r = to5bits(color.r);
            ubyte g = to5bits(color.g);
            ubyte b = to5bits(color.b);
            ushort rgb = cast(ushort)(r << 10 | g << 5 | b);
            (cast(ushort*) ptr)[x] = rgb;
            break;
        case PixelFormat.Format16bppRgb565:
            ubyte r = to5bits(color.r);
            ubyte g = to6bits(color.g);
            ubyte b = to5bits(color.b);
            ushort rgb = cast(ushort)(r << 11 | g << 5 | b);
            (cast(ushort*) ptr)[x] = rgb;
            break;
        case PixelFormat.Format24bppRgbLE:
            (cast(ubyte[3]*) ptr)[x] = [color.b, color.g, color.r];
            break;
        case PixelFormat.Format24bppRgbBE:
            (cast(ubyte[3]*) ptr)[x] = [color.r, color.g, color.b];
            break;
        case PixelFormat.Format32bppXrgb:
            uint xrgb = 0xFF << 24 | color.rgba >> 8;
            (cast(uint*) ptr)[x] = xrgb;
            break;
        case PixelFormat.Format32bppArgb:
            uint argb = color.a << 24 | color.rgba >> 8;
            (cast(uint*) ptr)[x] = argb;
            break;
        case PixelFormat.Format32bppRgba:
            (cast(uint*) ptr)[x] = color.rgba;
            break;
        case flipEndian(PixelFormat.Format16bppRgb555):
            ubyte r = to5bits(color.r);
            ubyte g = to5bits(color.g);
            ubyte b = to5bits(color.b);
            ushort val = cast(ushort)(g << 13 | b << 8 | r << 2 | g >> 3);
            (cast(ushort*) ptr)[x] = val;
            break;
        case flipEndian(PixelFormat.Format16bppRgb565):
            ubyte r = to5bits(color.r);
            ubyte g = to6bits(color.g);
            ubyte b = to5bits(color.b);
            ushort val = cast(ushort)(g << 13 | b << 8 | r << 3 | g >> 3);
            (cast(ushort*) ptr)[x] = val;
            break;
        case flipEndian(PixelFormat.Format32bppXrgb):
            uint bgrx = color.b << 24 | color.g << 16 | color.r << 8 | 0xFF;
            (cast(uint*) ptr)[x] = bgrx;
            break;
        case flipEndian(PixelFormat.Format32bppArgb):
            uint bgra = color.b << 24 | color.g << 16 | color.r << 8 | color.a;
            (cast(uint*) ptr)[x] = bgra;
            break;
        case flipEndian(PixelFormat.Format32bppRgba):
            uint abgr = color.a << 24 | color.b << 16 | color.g << 8 | color.r;
            (cast(uint*) ptr)[x] = abgr;
            break;
        }
    }

    @nogc @system private void writeColor(void* ptr, size_t x, Color color) nothrow
    {
        writeColor(this.pixelFormat, this.palette, ptr, x, color);
    }

    /**
     * Gets the color of the specified pixel in this image.
     *
     * Params:
     *     x =
     *         The X coordinate of the pixel to retrieve, from left to right.
     *         It must be between 0 (included) and the width of the image (excluded).
     *     y =
     *         The Y coordinate of the pixel to retrieve, from top to bottom, or from bottom to top, according to the [bottomUp] property.
     *         It must be between 0 (included) and the height of the image (excluded).
     *
     * Return: A [Color] object that represents the color of the specified pixel.
     *
     * Throws: If the pixel format is indexed and the specified pixel has a value which is out of bounds for the color table.
     */
    @trusted public Color getPixel(int x, int y) const
    in
    {
        assert(0 <= x && x < this.width);
        assert(0 <= y && y < this.height);
    }
    do
    {
        const void* ptr = this.data.ptr + y * this.stride;
        return this.readColor(ptr, x + this.skipX);
    }

    /**
     * Sets the color of the specified pixel in this image. If the color isn't allowed by the pixel format or, for an indexed format, by the color table, an approximation will be used.
     *
     * Params:
     *     x =
     *         The X coordinate of the pixel to set, from left to right.
     *         It must be between 0 (included) and the width of the image (excluded).
     *     y =
     *         The Y coordinate of the pixel to set, from top to bottom or from bottom to top, according to the [bottomUp] property.
     *         It must be between 0 (included) and the height of the image (excluded).
     *     color = The color to assign to the specified pixel.
     */
    @nogc @trusted public void setPixel(int x, int y, Color color) nothrow
    in
    {
        assert(0 <= x && x < this.width);
        assert(0 <= y && y < this.height);
    }
    do
    {
        void* ptr = this.data.ptr + y * this.stride;
        this.writeColor(ptr, x + this.skipX, color);
    }

    /**
     * Checks whether the image is fully opaque.
     *
     * Returns: `true` if the image is fully opaque, `false` otherwise.
     *
     * Throws: If the pixel format is indexed, the color table contains both fully opaque and fully or partially transparent pixels and there are pixels with invalid values.
     */
    @trusted public bool opaque() const
    {
        if (this.indexed)
        {
            bool allOpaque = false;
            bool noneOpaque = false;
            for (int i = 0; i < this.palette.length; i++)
            {
                if (this.palette[i].a == 255)
                {
                    noneOpaque = false;
                }
                else
                {
                    allOpaque = false;
                }
            }
            if (allOpaque)
            {
                return true;
            }
            if (noneOpaque)
            {
                return false;
            }
        }
        else if (canFind([
            PixelFormat.Format8bppGray, PixelFormat.Format16bppRgb555BE,
            PixelFormat.Format16bppRgb555LE, PixelFormat.Format16bppRgb565BE,
            PixelFormat.Format16bppRgb565LE, PixelFormat.Format24bppRgbBE,
            PixelFormat.Format24bppRgbLE, PixelFormat.Format32bppXrgbBE,
            PixelFormat.Format32bppXrgbLE
        ], this.pixelFormat))
        {
            return true;
        }
        const(void)* ptr = this.data.ptr;
        for (int y = 0; y < this.height; y++)
        {
            for (int x = 0; x < this.width; x++)
            {
                Color color = this.readColor(ptr, this.skipX + x);
                if (color.a != 255)
                {
                    return false;
                }
            }
            ptr += this.stride;
        }
        return true;
    }

    /**
     * Checks whether all pixels in the image are valid.
     *
     * Returns:
     *     `true` if all pixels in the image are valid, which is always the case for non-indexed formats, as well as for indexed formats when the color table has the maximum length allowed by the format.
     *     `false` if the pixel format of the image is indexed and there is at least one pixel whose value is out of bounds for the color table.
     */
    @nogc @trusted public bool valid() const nothrow
    {
        if (this.indexed && this.palette.length < 1 << this.bpp)
        {
            const(ubyte)* ptr = this._data.ptr;
            for (int y = 0; y < this.height; y++)
            {
                for (int x = 0; x < this.width; x++)
                {
                    ubyte index;
                    switch (this.pixelFormat)
                    {
                    case PixelFormat.Format1bppIndexed:
                        index = ptr[x / 8] >> (7 - x % 8) & 1;
                        break;
                    case PixelFormat.Format4bppIndexed:
                        index = ptr[x / 2] >> ((1 - x % 2) * 4) & 0xF;
                        break;
                    case PixelFormat.Format8bppIndexed:
                        index = ptr[x];
                        break;
                    default:
                        assert(0);
                    }
                    if (index >= this.palette.length)
                    {
                        return false;
                    }
                }
            }
            ptr += this.stride;
        }
        return true;
    }

    /**
     * Creates a rectangular slice of the image that shares its pixel data.
     *
     * Params:
     *     rect =
     *         The axes-aligned rectangle to be used for slicing.
     *         It must fit in the image in its entirety.
     *
     * Returns: The rectangular slice, as a new [Bitmap] object which shares pixel data with this image.
     */
    public inout(Bitmap) slice(Rectangle rect) inout nothrow
    in
    {
        assert(rect.x >= 0);
        assert(rect.y >= 0);
        assert(rect.width >= 0);
        assert(rect.height >= 0);
        assert(rect.x + rect.width <= this.width);
        assert(rect.y + rect.height <= this.height);
    }
    do
    {
        size_t skipX = this.skipX + rect.x;
        inout void[] data = this.data[this.stride * rect.y .. this.stride * (rect.y + rect.height)];
        return new inout Bitmap(rect.width, rect.height, skipX, this.stride,
                this.pixelFormat, this.palette, this.bottomUp, data);
    }

    /**
     * Creates an independent copy of this image which does not share its pixel data.
     *
     * Returns: The created copy of the image.
     */
    @trusted public Bitmap clone() const nothrow
    {
        Bitmap bmp = new Bitmap(this.width, this.height, this.pixelFormat, this.palette);
        auto yRange = this.yTopDown;
        for (int y = 0; y < this.height; y++)
        {
            this.rawLine(yRange[y], bmp.data.ptr + bmp.stride * y, bmp.skipX);
        }
        return bmp;
    }

    @nogc @system private template Dim(T)
    {
        void flipHor() nothrow
        {
            void* ptr = this.data.ptr;
            for (int y = 0; y < this.height; y++)
            {
                T[] row = (cast(T*) ptr)[this.skipX .. this.skipX + this.width];
                reverse(row);
                ptr += this.stride;
            }
        }

        void flipVer() nothrow
        {
            void* ptr1 = this.data.ptr;
            void* ptr2 = this.data.ptr + this.data.length - this.stride;
            for (int y = 0; y < this.height / 2; y++)
            {
                T[] row1 = (cast(T*) ptr1)[this.skipX .. this.skipX + this.width];
                T[] row2 = (cast(T*) ptr2)[this.skipX .. this.skipX + this.width];
                swapRanges(row1, row2);
                ptr1 += this.stride;
                ptr2 -= this.stride;
            }
        }

        void flip() nothrow
        {
            void* ptr1 = this.data.ptr;
            void* ptr2 = this.data.ptr + this.stride * (this.height - 1);
            for (int y = 0; y < this.height / 2; y++)
            {
                T[] row1 = (cast(T*) ptr1)[this.skipX .. this.skipX + this.width];
                T[] row2 = (cast(T*) ptr2)[this.skipX .. this.skipX + this.width];
                for (int x = 0; x < this.width; x++)
                {
                    swap(row1[x], row2[$ - x - 1]);
                }
                ptr1 += this.stride;
                ptr2 -= this.stride;
            }
            if (this.height % 2 == 1)
            {
                T[] row = (cast(T*) ptr1)[this.skipX .. this.skipX + this.width];
                reverse(row);
            }
        }

        void rawLineSwapEndian(int y, void* dest, size_t skipX) const
        in (this.bpp >= 8)
        {
            T[] row1 = (cast(T*) dest)[skipX .. skipX + this.width];
            const(void)* ptr2 = this.data.ptr + this.stride * y;
            T[] row2 = (cast(T*) ptr2)[this.skipX .. this.skipX + this.width];
            for (int x = 0; x < this.width; x++)
            {
                static if (__traits(isIntegral, T))
                {
                    row1[x] = swapEndian(row2[x]);
                }
                else static if (__traits(isStaticArray, T))
                {
                    row1[x] = row2[x];
                    reverse(row1[x][]);
                }
                else
                {
                    static assert(0);
                }
            }
        }

        void from(const Bitmap source, bool transpose, bool flipHor, bool flipVer)
        in
        {
            if (transpose)
            {
                assert(source.width == this.height);
                assert(source.height == this.width);
            }
            else
            {
                assert(source.width == this.width);
                assert(source.height == this.height);
            }
        }
        do
        {
            const(void)* ptr2 = source.data.ptr;
            foreach (int y; 0 .. source.height)
            {
                T[] row2 = (cast(T*) ptr2)[source.skipX .. source.skipX + source.width];
                foreach (int x; 0 .. source.width)
                {
                    T value = row2[x];
                    if (transpose)
                    {
                        swap(x, y);
                    }
                    if (flipHor)
                    {
                        x = this.width - x - 1;
                    }
                    if (flipVer)
                    {
                        y = this.height - y - 1;
                    }
                    void* ptr1 = this.data.ptr + this.stride * y;
                    T[] row1 = (cast(T*) ptr1)[this.skipX .. this.skipX + this.width];
                    row1[x] = value;
                }
                ptr2 += source.stride;
            }
        }

        void fromSwapEndian(const Bitmap source, bool transpose, bool flipHor, bool flipVer)
        in
        {
            if (transpose)
            {
                assert(source.width == this.height);
                assert(source.height == this.width);
            }
            else
            {
                assert(source.width == this.width);
                assert(source.height == this.height);
            }
        }
        do
        {
            const(void)* ptr2 = source.data.ptr;
            foreach (int y; 0 .. source.height)
            {
                T[] row2 = (cast(T*) ptr2)[source.skipX .. source.skipX + source.width];
                foreach (int x; 0 .. source.width)
                {
                    T value = row2[x];
                    if (transpose)
                    {
                        swap(x, y);
                    }
                    if (flipHor)
                    {
                        x = this.width - x - 1;
                    }
                    if (flipVer)
                    {
                        y = this.height - y - 1;
                    }
                    void* ptr1 = this.data.ptr + this.stride * y;
                    T[] row1 = (cast(T*) ptr1)[this.skipX .. this.skipX + this.width];
                    static if (__traits(isIntegral, T))
                    {
                        row1[x] = swapEndian(value);
                    }
                    else static if (__traits(isStaticArray, T))
                    {
                        reverse(value[]);
                        row1[x] = value;
                    }
                    else
                    {
                        static assert(0);
                    }
                }
                ptr2 += source.stride;
            }
        }
    }

    private alias Dim(int D) = Dim!(ubyte[D]);

    @system private void sized(string Func, T...)(T a)
    {
        template Gen(string A, string B)
        {
            immutable string Gen = "Bitmap.Dim!" ~ A ~ "." ~ B;
        }

        final switch (this.bpp)
        {
        case 8:
            mixin(Gen!("ubyte", Func))(a);
            break;
        case 16:
            mixin(Gen!("ushort", Func))(a);
            break;
        case 24:
            mixin(Gen!("3", Func))(a);
            break;
        case 32:
            mixin(Gen!("uint", Func))(a);
            break;
        }
    }

    @nogc @system private void sized(string Func, T...)(T a) const
    {
        template Gen(string A, string B)
        {
            immutable string Gen = "Bitmap.Dim!" ~ A ~ "." ~ B;
        }

        final switch (this.bpp)
        {
        case 8:
            mixin(Gen!("ubyte", Func))(a);
            break;
        case 16:
            mixin(Gen!("ushort", Func))(a);
            break;
        case 24:
            mixin(Gen!("3", Func))(a);
            break;
        case 32:
            mixin(Gen!("uint", Func))(a);
            break;
        }
    }

    /**
     * Flips the image in place horizontally (along its vertical axis).
     * Unused bits and color indices referring to identical colors are preserved exactly.
     */
    @trusted public void flipHor() nothrow
    {
        switch (this.pixelFormat)
        {
        case PixelFormat.Format1bppIndexed:
            ubyte* ptr = this._data.ptr;
            bool[] bits = new bool[(this.skipX % 8 + this.width + 7) & ~(cast(size_t) 0b111)];
            for (int y = 0; y < this.height; y++)
            {
                assumeWontThrow(flipBits(ptr, this.skipX, this.width, bits));
                ptr += this.stride;
            }
            break;
        case PixelFormat.Format4bppIndexed:
            ubyte* ptr = this._data.ptr;
            ubyte[] values = new ubyte[this.width];
            for (int y = 0; y < this.height; y++)
            {
                for (int x = 0; x < this.width; x++)
                {
                    size_t offset = this.skipX + x;
                    if (offset % 2 == 0)
                    {
                        values[x] = ptr[offset / 2] >> 4;
                    }
                    else
                    {
                        values[x] = ptr[offset / 2] & 0xF;
                    }
                }
                if (this.skipX % 2 == 1)
                {
                    ptr[this.skipX / 2] = (ptr[this.skipX / 2] & 0b11110000) | values[$ - 1];
                    for (int x = 1; x < this.width; x += 2)
                    {
                        ptr[(this.skipX + x) / 2] = cast(ubyte)(
                                values[$ - x - 2] << 4 | values[$ - x - 3]);
                    }
                    if (this.width % 2 == 0)
                    {
                        ptr[(this.skipX + this.width) / 2] = cast(ubyte)(
                                values[0] << 4 | (ptr[(this.skipX + this.width) / 2] & 0xF));
                    }
                }
                else
                {
                    for (int x = 0; x < this.width - 1; x += 2)
                    {
                        ptr[(this.skipX + x) / 2] = cast(ubyte)(
                                values[$ - x - 1] << 4 | values[$ - x - 2]);
                    }
                    if (this.width % 2 == 1)
                    {
                        ptr[(this.skipX + this.width) / 2] = cast(ubyte)(
                                values[0] << 4 | (ptr[(this.skipX + this.width) / 2] & 0xF));
                    }
                }
                ptr += this.stride;
            }
            break;
        default:
            assert(this.bpp >= 8);
            this.sized!"flipHor"();
            break;
        }
    }

    /**
     * Flips the image in place vertically (along its horizontal axis).
     * Unused bits and color indices referring to identical colors are preserved exactly.
     * The `flipVer` property is unchanged.
     */
    @trusted public void flipVer() nothrow
    {
        switch (this.pixelFormat)
        {
        case PixelFormat.Format1bppIndexed, PixelFormat.Format4bppIndexed:
            ubyte* ptr1 = this._data.ptr;
            ubyte* ptr2 = this._data.ptr + this.data.length - this.stride;
            size_t bits = this.width * this.bpp;
            size_t offset = this.skipX * this.bpp;
            size_t auxOffset = this.skipX % 8;
            ubyte[] aux = new ubyte[minStride(auxOffset, this.width, this.bpp)];
            for (int y = 0; y < this.height / 2; y++)
            {
                assumeWontThrow(copyBitsBuffer(aux.ptr, auxOffset, ptr1, offset, bits));
                assumeWontThrow(copyBitsBuffer(ptr1, offset, ptr2, offset, bits));
                assumeWontThrow(copyBitsBuffer(ptr2, offset, aux.ptr, auxOffset, bits));
                ptr1 += this.stride;
                ptr2 -= this.stride;
            }
            break;
        default:
            assert(this.bpp >= 8);
            this.sized!"flipVer"();
            break;
        }
    }

    /**
     * Rotates the image in place by a half circle.
     * Unused bits and color indices referring to identical colors are preserved exactly.
     */
    @trusted public void flip() nothrow
    {
        switch (this.pixelFormat)
        {
        case PixelFormat.Format1bppIndexed:
            for (int y = 0; y < this.height / 2; y++)
            {
                for (int x = 0; x < this.width; x++)
                {
                    size_t pos1 = this.stride * y + (this.skipX + x) / 8;
                    size_t pos2 = this.stride * (height - y - 1) + (this.skipX + this.width - x - 1) / 8;
                    ubyte val1 = this._data[pos1];
                    ubyte val2 = this._data[pos2];
                    int shift1 = 7 - (this.skipX + x) % 8;
                    int shift2 = 7 - (this.skipX + this.width - x - 1) % 8;
                    bool bit1 = (val1 >> shift1) & 1;
                    bool bit2 = (val2 >> shift2) & 1;
                    val1 = cast(ubyte)((val1 & ~(1 << shift1)) | bit2 << shift1);
                    val2 = cast(ubyte)((val2 & ~(1 << shift2)) | bit1 << shift2);
                    this._data[pos1] = val1;
                    this._data[pos2] = val2;
                }
            }
            if (this.height % 2 == 1)
            {
                assumeWontThrow(flipBits(this._data.ptr + this.stride * (this.height / 2 + 1),
                        this.skipX, this.width));
            }
            break;
        case PixelFormat.Format4bppIndexed:
            for (int y = 0; y < this.height / 2; y++)
            {
                for (int x = 0; x < this.width; x++)
                {
                    size_t offset1 = this.skipX + x;
                    size_t offset2 = this.skipX + this.width - x - 1;
                    size_t pos1 = this.stride * y + offset1 / 2;
                    size_t pos2 = this.stride * (this.height - y - 1) + offset2 / 2;
                    ubyte val1 = (this._data[pos1] >> (4 * (1 - offset1 % 2))) & 0xF;
                    ubyte val2 = (this._data[pos2] >> (4 * (1 - offset2 % 2))) & 0xF;
                    this._data[pos1] = cast(ubyte)((this._data[pos1] & 0xF << (
                            4 * (offset1 % 2))) | val2 << (4 * (1 - offset1 % 2)));
                    this._data[pos2] = cast(ubyte)((this._data[pos2] & 0xF << (
                            4 * (offset2 % 2))) | val1 << (4 * (1 - offset2 % 2)));
                }
            }
            if (this.height % 2 == 1)
            {
                ubyte* ptr = this._data.ptr + (this.height / 2) * this.stride;
                ubyte[] values = new ubyte[this.width];
                for (int x = 0; x < this.width; x++)
                {
                    size_t offset = this.skipX + x;
                    if (offset % 2 == 0)
                    {
                        values[x] = ptr[offset / 2] >> 4;
                    }
                    else
                    {
                        values[x] = ptr[offset / 2] & 0xF;
                    }
                }
                if (this.skipX % 2 == 1)
                {
                    ptr[this.skipX / 2] = (ptr[this.skipX / 2] & 0b11110000) | values[$ - 1];
                    for (int x = 1; x < this.width; x += 2)
                    {
                        ptr[(this.skipX + x) / 2] = cast(ubyte)(
                                values[$ - x - 2] << 4 | values[$ - x - 3]);
                    }
                    if (this.width % 2 == 0)
                    {
                        ptr[(this.skipX + this.width) / 2] = cast(ubyte)(
                                values[$ - 1] << 4 | (ptr[(this.skipX + this.width) / 2] & 0xF));
                    }
                }
                else
                {
                    for (int x = 0; x < this.width - 1; x += 2)
                    {
                        ptr[(this.skipX + x) / 2] = cast(ubyte)(
                                values[$ - x - 1] << 4 | values[$ - x - 2]);
                    }
                    if (this.width % 2 == 1)
                    {
                        ptr[(this.skipX + this.width) / 2] = cast(ubyte)(
                                values[$ - 1] << 4 | (ptr[(this.skipX + this.width) / 2] & 0xF));
                    }
                }
            }
            break;
        default:
            assert(this.bpp >= 8);
            this.sized!"flip"();
            break;
        }
    }

    /**
     * Copies a line of pixel data to the specified destination.
     *
     * Params:
     *     y = The Y coordinate of the line to be copied.
     *     dest =
     *         The destination to be written to.
     *         The pointer must be aligned to the alignment size of the pixel format.
     *         Enough space for the data must be available.
     *     skipX = The amount of positions to skip from `dest`, in pixel size.
     */
    @nogc @system public void rawLine(int y, void* dest, size_t skipX = 0) const nothrow
    in ((cast(size_t) dest) % alignSize == 0)
    {
        const(ubyte)* ptr = this._data.ptr + this.stride * y;
        copyBitsBuffer(cast(ubyte*) dest, skipX * this.bpp, ptr,
                this.skipX * this.bpp, this.width * this.bpp);
    }

    /**
     * Converts a line of pixel data to the given pixel format and copies it to the specified destination.
     * If the specified pixel format is indexed and the same as the source one and the two color tables are equal, the specified pixel format is non-indexed and the same as the source one or the given pixel format and the source one are non-indexed and correspond to each other with reverse byte order, all values are copied exactly and unused bits (if any, according to the pixel format) are preserved.
     * Otherwise, any unused bit is set to a default value (according to the pixel format), color table indices only depend on the color, in the case of duplicates, and colors are approximated if necessary.
     *
     * Params:
     *     y = The Y coordinate of the line.
     *     dest =
     *         The destination to be written to.
     *         The pointer must be aligned to the alignment size of the target pixel format.
     *         Enough space for the data must be available.
     *     skipX = The amount of positions to skip from `dest`, in pixel size, according to the target pixel format.
     *     pixelFormat = The target pixel format.
     *     palette =
     *         The target color table.
     *         For an indexed pixel format, it must have a length between 1 and the maximum for that format.
     *         For a non-indexed format, it must be an empty array.
     *
     * Throws: If the specified pixel format and color table aren't equal to those of the image and the line contains invalid pixels.
     */
    @system public void rawLine(int y, void* dest, size_t skipX,
            PixelFormat pixelFormat, const(Color)[] palette = null) const
    in
    {
        if (pixelFormat.indexed)
        {
            assert((cast(size_t) dest) % alignSize == 0);
            assert(palette == null || palette.length <= 1 << pixelFormat.bpp);
        }
        else
        {
            assert(palette == null);
        }
    }
    do
    {
        if (palette == null)
        {
            palette = this.palette;
        }
        if (pixelFormat == this.pixelFormat && palette == this.palette)
        {
            this.rawLine(y, dest, skipX);
        }
        else if (this.palette == null && pixelFormat == swapEndian(this.pixelFormat))
        {
            this.sized!"rawLineSwapEndian"(y, dest, skipX);
        }
        else
        {
            foreach (int x, Color color; this.scanLine(y))
            {
                writeColor(pixelFormat, palette, dest, skipX + x, color);
            }
        }
    }

    @trusted private void copyFrom(const Bitmap source, bool flipVer)
    in
    {
        assert(source.width == this.width);
        assert(source.height == this.height);
    }
    do
    {
        auto ySource = flipVer ? iota(source.height - 1, -1, -1) : iota(0, source.height, 1);
        for (int y = 0; y < this.height; y++)
        {
            source.rawLine(ySource[y], this.data.ptr + this.stride * y,
                    this.skipX, this.pixelFormat, this.palette);
        }
    }

    /**
     * Copies the content of the specified image onto this one.
     * If the two images have the same indexed pixel format and equal color tables, have the same non-indexed format or have non-indexed formats wich correspond to each other with reverse byte order all values are copied exactly and unused bits (if any, according to the pixel format) are preserved.
     * Otherwise, any unused bit is set to a default value (according to the pixel format), color table indices only depend on the color, in the case of duplicates, and colors are approximated if necessary.
     *
     * Params:
     *     source =
     *         The source image to be copied from.
     *         It must have the same width and height as this image.
     *
     * Throws: If the source image has a different pixel format or color table and contains invalid pixels.
     */
    public void copyFrom(const Bitmap source)
    in
    {
        assert(source.width == this.width);
        assert(source.height == this.height);
    }
    do
    {
        this.copyFrom(source, this.bottomUp ^ source.bottomUp);
    }

    /**
     * Transfers the content of the specified image onto this one, applying the specified transformations.
     * If the two images have the same indexed pixel format and equal color tables, have the same non-indexed format or have non-indexed formats wich correspond to each other with reverse byte order all values are copied exactly and unused bits (if any, according to the pixel format) are preserved.
     * Otherwise, any unused bit is set to a default value (according to the pixel format), color table indices only depend on the color, in the case of duplicates, and colors are approximated if necessary.
     *
     * Params:
     *     source =
     *         The source image to be copied from.
     *         If `transpose` is `false` it must have the same width and height as this image.
     *         If `transpose` is `true`, it must have a width equal to the height of this image and a height equal to the width of this image.
     *     transpose = Whether the source image is to be transposed.
     *     flipHor =
     *         Whether the source image is to be flipped horizontally.
     *         If `transpose` and `flipHor` are both `true`, flipping happens after transposing.
     *     flipVer =
     *         Whether the source image is to be flipped vertically.
     *         If `transpose` and `flipVer` are both `true`, flipping happens after transposing.
     *
     * Throws: If the source image has a different pixel format or color table and contains invalid pixels.
     */
    @trusted public void from(const Bitmap source, bool transpose, bool flipHor, bool flipVer)
    in
    {
        if (transpose)
        {
            assert(source.width == this.height);
            assert(source.height == this.width);
        }
        else
        {
            assert(source.width == this.width);
            assert(source.height == this.height);
        }
    }
    do
    {
        if (transpose || flipHor)
        {
            if (this.bpp >= 8 && source.palette == this.palette)
            {
                if (source.pixelFormat == this.pixelFormat)
                {
                    this.sized!"from"(source, transpose, flipHor, flipVer);
                    return;
                }
                if (source.pixelFormat == flipEndian(source.pixelFormat))
                {
                    this.sized!"fromSwapEndian"(source, transpose, flipHor, flipVer);
                    return;
                }
            }
            const(void)* ptr2 = source.data.ptr;
            if (this.indexed && source.pixelFormat == this.pixelFormat
                    && source.palette == this.palette)
            {
                foreach (int y; 0 .. source.height)
                {
                    foreach (int x; 0 .. source.width)
                    {
                        uint index;
                        if (source.pixelFormat == PixelFormat.Format1bppIndexed)
                        {
                            index = ((cast(ubyte*) ptr2)[(source.skipX + x) / 8]) >> (7 - x % 8) & 1;
                        }
                        else
                        {
                            assert(source.pixelFormat == PixelFormat.Format4bppIndexed);
                            index = ((cast(ubyte*) ptr2)[(source.skipX + x) / 2]) >> ((1 - x % 2)
                                    * 4) & 0xF;
                        }
                        if (transpose)
                        {
                            swap(x, y);
                        }
                        if (flipHor)
                        {
                            x = this.width - x - 1;
                        }
                        if (flipVer)
                        {
                            y = this.height - y - 1;
                        }
                        void* ptr1 = this.data.ptr + this.stride * y;
                        if (this.pixelFormat == PixelFormat.Format1bppIndexed)
                        {
                            if (index)
                            {
                                (cast(ubyte*) ptr1)[(this.skipX + x) / 8] |= 1 << (7 - x % 8);
                            }
                            else
                            {
                                (cast(ubyte*) ptr1)[(this.skipX + x) / 8] &= ~(1 << (7 - x % 8));
                            }
                        }
                        else
                        {
                            ubyte vals = (cast(ubyte*) ptr1)[x / 2];
                            vals &= ~(1 << ((1 - (this.skipX + x) % 2) * 4));
                            vals |= index << ((1 - (this.skipX + x) % 2) * 4);
                            (cast(ubyte*) ptr1)[(this.skipX + x) / 2] = vals;
                        }
                    }
                    ptr2 += source.stride;
                }
            }
            else
            {
                foreach (int y; 0 .. source.height)
                {
                    foreach (int x; 0 .. source.width)
                    {
                        Color color = source.readColor(ptr2, source.skipX + x);
                        if (transpose)
                        {
                            swap(x, y);
                        }
                        if (flipHor)
                        {
                            x = this.width - x - 1;
                        }
                        if (flipVer)
                        {
                            y = this.height - y - 1;
                        }
                        void* ptr1 = this.data.ptr + this.stride * y;
                        this.writeColor(ptr1, this.skipX + x, color);
                    }
                    ptr2 += source.stride;
                }
            }
        }
        else
        {
            this.copyFrom(source, flipVer);
        }
    }

    /**
     * Blends the given foreground image on top of this image.
     * This image must use a pixel format with at least 24 bits per pixel.
     *
     * Params:
     *     foreground =
     *         The foreground image to blend on top of this one.
     *         It must have the same width and height as this image.
     */
    @trusted public void blendFrom(const Bitmap foreground)
    in
    {
        assert(foreground.width == this.width);
        assert(foreground.height == this.height);
        assert(this.bpp >= 24);
    }
    do
    {
        void* ptr1 = this.data.ptr;
        bool flipVer = this.bottomUp ^ foreground.bottomUp;
        auto ySource = flipVer ? iota(foreground.height - 1, -1, -1) : iota(0, foreground.height, 1);
        for (int y = 0; y < this.height; y++)
        {
            const(void)* ptr2 = foreground.data.ptr + ySource[y] * foreground.stride;
            for (int x = 0; x < this.width; x++)
            {
                Color backColor = this.readColor(ptr1, this.skipX + x);
                Color frontColor = foreground.readColor(ptr2, foreground.skipX + x);
                Color color = blend(backColor, frontColor);
                this.writeColor(ptr1, this.skipX + x, color);
            }
            ptr1 += this.stride;
        }
    }

    /**
     * Blends this image with the given one.
     * This image must use a pixel format compatible with the operation.
     * Unless both images use the [PixelFormat.Format8bppGray] pixel format, which is allowed, this image must use a pixel format with at least 24 bits per pixel.
     * Unless the given other image is opaque, this image must use a pixel format which allows transparency.
     *
     * Params:
     *     other = The other image this one must be mixed with.
     *     factor = The mixing factor to be used, between and including 0 and 1.
     */
    @trusted public void mixFrom(const Bitmap other, float factor = 0.5)
    in
    {
        assert(other.width == this.width);
        assert(other.height == this.height);
        assert(0 <= factor && factor <= 1);
        if (this.pixelFormat == PixelFormat.Format8bppGray)
        {
            assert(other.pixelFormat == PixelFormat.Format8bppGray);
        }
        else
        {
            assert(this.bpp >= 24);
            if (!among!(PixelFormat.Format32bppArgbBE, PixelFormat.Format32bppArgbLE,
                    PixelFormat.Format32bppRgbaBE, PixelFormat.Format32bppRgbaLE)(this.pixelFormat))
            {
                assert(other.opaque());
            }
        }
    }
    do
    {
        void* ptr1 = this.data.ptr;
        bool flipVer = this.bottomUp ^ other.bottomUp;
        auto ySource = flipVer ? iota(other.height - 1, -1, -1) : iota(0, other.height, 1);
        for (int y = 0; y < this.height; y++)
        {
            const(void)* ptr2 = other.data.ptr + ySource[y] * other.stride;
            for (int x = 0; x < this.width; x++)
            {
                Color color1 = this.readColor(ptr1, this.skipX + x);
                Color color2 = other.readColor(ptr2, other.skipX + x);
                Color color = mix(color1, color2, factor);
                this.writeColor(ptr1, this.skipX + x, color);
            }
            ptr1 += this.stride;
        }
    }

    /**
     * Checks whether the given image has the same color as this image for every pixel.
     * The [bottomUp] property of both images is accounted for.
     *
     * Params:
     *   bmp =
     *       The image to be compared to this one.
     *       It must have the same width and height as this image.
     *   oneTransparency = Whether all fully transparent colors are to be regarded as identical.
     *
     * Returns: `true` if the two images are identical, `false` otherwise.
     *
     * Throws: If either image has invalid pixels.
     */
    @trusted public bool equals(const Bitmap bmp, bool oneTransparency = true) const
    {
        if (bmp.width != this.width || bmp.height != this.height)
        {
            return false;
        }
        const(void)* ptr1 = this.data.ptr;
        auto yBmp = (this.bottomUp ^ bmp.bottomUp) ? iota(bmp.height - 1, -1, -1) : iota(0,
                bmp.height, 1);
        for (int y = 0; y < this.height; y++)
        {
            const(void)* ptr2 = bmp.data.ptr + bmp.stride * yBmp[y];
            for (int x = 0; x < this.width; x++)
            {
                Color color1 = bmp.readColor(ptr2, x);
                Color color2 = this.readColor(ptr1, x);
                if (color1 != color2 && !(oneTransparency && color1.a == 0 && color2.a == 0))
                {
                    return false;
                }
            }
            ptr1 += this.stride;
        }
        return true;
    }

    /**
     * Fills the image with the given color or its approximation.
     *
     * Params:
     *     color = The color to fill the image with.
     */
    @nogc @trusted public void paint(Color color) nothrow
    {
        void* ptr = this.data.ptr;
        for (int y = 0; y < this.height; y++)
        {
            final switch (this.pixelFormat)
            {
            case PixelFormat.Format1bppIndexed:
                bool bit = !!colorIndex(palette, color);
                fillBitsBuffer(cast(ubyte*) ptr, this.skipX, this.width, bit);
                break;
            case PixelFormat.Format4bppIndexed:
                ubyte index = colorIndex(palette, color);
                ubyte val = cast(ubyte)(index << 4 | index);
                if (this.skipX % 2 == 1)
                {
                    (cast(ubyte*) ptr)[this.skipX / 2] = ((cast(ubyte*) ptr)[this.skipX / 2] & 0xF0) | (
                            val & 0x0F);
                }
                if (this.width == 1)
                {
                    if (this.skipX % 2 == 0)
                    {
                        (cast(ubyte*) ptr)[this.skipX / 2] = (val & 0xF0) | (
                                (cast(ubyte*) ptr)[this.skipX / 2] & 0x0F);
                    }
                }
                else
                {
                    size_t bytes = (this.width - this.skipX % 2) / 2;
                    size_t pos = (this.skipX + 1) / 2;
                    (cast(ubyte*) ptr)[pos .. pos + bytes] = val;
                    if ((this.width - this.skipX % 2) % 2 == 1)
                    {
                        (cast(ubyte*) ptr)[pos + bytes] = (val & 0xF0) | (
                                (cast(ubyte*) ptr)[pos] & 0x0F);
                    }
                }
                break;
            case PixelFormat.Format8bppIndexed:
                ubyte index = colorIndex(palette, color);
                (cast(ubyte*) ptr)[this.skipX .. this.skipX + this.width] = index;
                break;
            case PixelFormat.Format8bppGray:
                (cast(ubyte*) ptr)[this.skipX .. this.skipX + this.width] = color.luma;
                break;
            case PixelFormat.Format16bppRgb555:
                ubyte r = to5bits(color.r);
                ubyte g = to5bits(color.g);
                ubyte b = to5bits(color.b);
                ushort rgb = cast(ushort)(r << 10 | g << 5 | b);
                (cast(ushort*) ptr)[this.skipX .. this.skipX + this.width] = rgb;
                break;
            case PixelFormat.Format16bppRgb565:
                ubyte r = to5bits(color.r);
                ubyte g = to6bits(color.g);
                ubyte b = to5bits(color.b);
                ushort rgb = cast(ushort)(r << 11 | g << 5 | b);
                (cast(ushort*) ptr)[this.skipX .. this.skipX + this.width] = rgb;
                break;
            case PixelFormat.Format24bppRgbLE:
                (cast(ubyte[3]*) ptr)[this.skipX .. this.skipX + this.width] = [
                    color.b, color.g, color.r
                ];
                break;
            case PixelFormat.Format24bppRgbBE:
                (cast(ubyte[3]*) ptr)[this.skipX .. this.skipX + this.width] = [
                    color.r, color.g, color.b
                ];
                break;
            case PixelFormat.Format32bppXrgb:
                uint xrgb = 0xFF | color.rgba >> 8;
                (cast(uint*) ptr)[this.skipX .. this.skipX + this.width] = xrgb;
                break;
            case PixelFormat.Format32bppArgb:
                uint argb = color.a | color.rgba >> 8;
                (cast(uint*) ptr)[this.skipX .. this.skipX + this.width] = argb;
                break;
            case PixelFormat.Format32bppRgba:
                (cast(uint*) ptr)[this.skipX .. this.skipX + this.width] = color.rgba;
                break;
            case flipEndian(PixelFormat.Format16bppRgb555):
                ubyte r = to5bits(color.r);
                ubyte g = to5bits(color.g);
                ubyte b = to5bits(color.b);
                ushort val = cast(ushort)(g << 13 | b << 8 | r << 2 | g >> 3);
                (cast(ushort*) ptr)[this.skipX .. this.skipX + this.width] = val;
                break;
            case flipEndian(PixelFormat.Format16bppRgb565):
                ubyte r = to5bits(color.r);
                ubyte g = to6bits(color.g);
                ubyte b = to5bits(color.b);
                ushort val = cast(ushort)(g << 13 | b << 8 | r << 3 | g >> 3);
                (cast(ushort*) ptr)[this.skipX .. this.skipX + this.width] = val;
                break;
            case flipEndian(PixelFormat.Format32bppXrgb):
                uint bgrx = color.b << 24 | color.g << 16 | color.r << 8 | 0xFF;
                (cast(uint*) ptr)[this.skipX .. this.skipX + this.width] = bgrx;
                break;
            case flipEndian(PixelFormat.Format32bppArgb):
                uint bgra = color.b << 24 | color.g << 16 | color.r << 8 | color.a;
                (cast(uint*) ptr)[this.skipX .. this.skipX + this.width] = bgra;
                break;
            case flipEndian(PixelFormat.Format32bppRgba):
                uint abgr = color.a << 24 | color.b << 16 | color.g << 8 | color.r;
                (cast(uint*) ptr)[this.skipX .. this.skipX + this.width] = abgr;
                break;
            }
            ptr += this.stride;
        }
    }

    @system private void readWrite(bool Read, bool Write, R, A...)(R delegate(A args) func)
            if ((Read || Write) && ((Write && (is(R == Color)
                || is(R == const Color))) || (!Write && is(R == void))))
    {
        void* ptr = this.data.ptr;
        for (int y = 0; y < this.height; y++)
        {
            for (int x = 0; x < this.width; x++)
            {
                static if (Read)
                {
                    Color color = this.readColor(ptr, x + this.skipX);
                }
                static if (Read && Write)
                {
                    color = func(x, y, color);
                }
                else static if (Read)
                {
                    func(x, y, color);
                }
                else static if (Write)
                {
                    Color color = func(x, y);
                }
                else
                {
                    static assert(0);
                }
                static if (Write)
                {
                    this.writeColor(ptr, x + this.skipX, color);
                }
            }
            ptr += this.stride;
        }
    }

    /**
     * Fills the image using with the colors produced, for each pixel, by the given function.
     *
     * Params:
     *     brush = The function to be used to fill the image.
     */
    @system public void paint(Color delegate(int x, int y) brush)
    {
        this.readWrite!(false, true)(brush);
    }

    /// ditto
    @trusted public void paint(Color delegate(int x, int y) @safe brush)
    {
        this.paint(cast(Color delegate(int, int) @system) brush);
    }

    /// ditto
    @system public void paint(Color delegate(int x, int y, Color prevColor) brush)
    {
        this.readWrite!(true, true)(brush);
    }

    /// ditto
    @trusted public void paint(Color delegate(int x, int y, Color prevColor) @safe brush)
    {
        this.paint(cast(Color delegate(int, int, Color) @system) brush);
    }

    /**
     * Repeats the given action for each pixel in the image.
     *
     * Params:
     *     action = The action to be repeated.
     */
    @system public void forEach(void delegate(int x, int y) action) const
    {
        for (int y = 0; y < this.height; y++)
        {
            for (int x = 0; x < this.width; x++)
            {
                action(x, y);
            }
        }
    }

    /// ditto
    @trusted public void forEach(void delegate(int x, int y) @safe action) const
    {
        this.forEach(cast(void delegate(int, int) @system) action);
    }

    /// ditto
    @system public void forEach(void delegate(int x, int y, Color color) action) const
    {
        (cast(Bitmap) this).readWrite!(true, false)(action);
    }

    /// ditto
    @trusted public void forEach(void delegate(int x, int y, Color color) @safe action) const
    {
        this.forEach(cast(void delegate(int, int, Color) @system) action);
    }

    /**
     * Produces a finite random-access range representing a row of pixels in the image.
     * The range provides a view on the data in the image and doesn't make an independent copy of it.
     *
     * Params:
     *     y = The Y coordinate of the row in the image.
     *
     * Returns: The produced finite random-access range.
     */
    @nogc public pure auto scanLine(int y) const nothrow
    in
    {
        assert(0 <= y && y < this.height);
    }
    out (result)
    {
        assert(!result.empty);
        assert(result.length == this.width);
    }
    do
    {
        static struct Result
        {
            private const Bitmap _self;
            private size_t _x0;
            private size_t _x1;
            private const(ubyte)* _ptr;

            private @nogc @trusted this(const Bitmap self, int y)
            in
            {
                assert(self !is null);
                assert(y < self.height);
            }
            do
            {
                this._x0 = self.skipX;
                this._x1 = self.skipX + self.width;
                this._self = self;
                this._ptr = self._data.ptr + self.stride * y;
            }

            /// The current pixel color, corresponding to the beginning of the range.
            /// Throws: If the pixel has an invalid value.
            public @property @trusted Color front() const
            in (!this.empty)
            {
                return this._self.readColor(this._ptr, this._x0);
            }

            /**
             * Moves the front of the range out and returns it.
             *
             * Returns: The value that has been removed from the range.
             *
             * Throws: If the pixel has an invalid value.
             */
            public @safe Color moveFront()
            in (!this.empty)
            {
                Color color = this.front();
                this.popFront();
                return color;
            }

            /*
             * Advances the beginning of the range by one element.
             */
            public @nogc @safe void popFront() nothrow
            in (!this.empty)
            {
                this._x0++;
            }

            /// Whether there is no longer any data to be retrieved.
            public @nogc @property @safe pure bool empty() const nothrow
            {
                return this._x0 >= this._x1;
            }

            public int opApply(scope int delegate(Color color) dg)
            {
                while (!this.empty)
                {
                    int result = dg(this.front());
                    this._x0++;
                    if (result != 0)
                    {
                        return result;
                    }
                }
                return 0;
            }

            public int opApply(scope int delegate(size_t x, Color color) dg)
            {
                size_t initX = this._x0;
                while (!this.empty)
                {
                    int result = dg(this._x0 - initX, this.front());
                    this._x0++;
                    if (result != 0)
                    {
                        return result;
                    }
                }
                return 0;
            }

            public int opApply(scope int delegate(int x, Color color) dg)
            {
                size_t initX = this._x0;
                while (!this.empty)
                {
                    int result = dg(cast(int)(this._x0 - initX), this.front());
                    this._x0++;
                    if (result != 0)
                    {
                        return result;
                    }
                }
                return 0;
            }

            /// A copy of the range, as a view on the same underlying data.
            public @nogc @property @safe Result save() const nothrow
            {
                return this;
            }

            /// The pixel color corresponding to the end of the array.
            /// Throws: If the pixel has an invalid value.
            public @property @trusted Color back() const
            in (!this.empty)
            {
                return this._self.readColor(this._ptr, this._x1 - 1);
            }

            /**
             * Moves the back of the range out and returns it.
             *
             * Returns: The value that was removed from the range.
             *
             * Throws: If the pixel has an invalid value.
             */
            public @safe Color moveBack()
            in (!this.empty)
            {
                Color color = this.back;
                this.popBack();
                return color;
            }

            /*
             * Removes an element from the back of the range.
             */
            public @nogc @safe void popBack() nothrow
            in (!this.empty)
            {
                this._x1--;
            }

            @trusted public Color opIndex(size_t x) const
            in
            {
                assert(!this.empty);
                assert(x < this.length);
            }
            do
            {
                return this._self.readColor(this._ptr, this._x0 + x);
            }

            /**
             * Moves the front of the range forward by the required number of elements and returns the new front.
             *
             * Params:
             *     x =
             *         The number of elements to be removed from the front of the range.
             *         It must be strictly less than the current length of the range.
             *
             * Returns: The new front of the range.
             */
            public @safe Color moveAt(size_t x)
            in
            {
                assert(!this.empty);
                assert(x < this.length);
            }
            do
            {
                this._x0 += x;
                return this.front;
            }

            /// The number of element in the range, initially equal to the width of the image.
            public @nogc @property @safe pure size_t length() const nothrow
            {
                return this._x1 - this._x0;
            }

            public alias opDollar = length;

            invariant (this._x0 <= this._x1);
        }

        static assert(isRandomAccessRange!Result);
        return Result(this, y);
    }

    /// A range of Y coordinate values scanning the image from top to bottom.
    @nogc @property public pure auto yTopDown() const nothrow
    {
        return this.bottomUp ? iota(this.height - 1, -1, -1) : iota(0, this.height, 1);
    }

    /// A range of Y coordinate values scanning the image from bootom to top.
    @nogc @property public pure auto yBottomUp() const nothrow
    {
        return this.bottomUp ? iota(0, this.height, 1) : iota(this.height - 1, -1, -1);
    }

    /**
     * Converts the image to a matrix of color values.
     *
     * Params:
     *     matrix =
     *         The output matrix, as a "jagged" rectangular array.
     *         If `transpose` is `false`, its length must be equal to the width of the image and that of each array it contains must be equal to the height of the image.
     *         If `transpose` is `true`, its length must be equal to the height of the image and that of each array it contains must be equal to the width of the image.
     *
     *     transpose =
     *         If `false`, the first index in the matrix represents the X coordinate and the second index represents the Y coordinate.
     *         If `true`, the first index in the matrix represents the Y coordinate and the second index represents the X coordinate.
     */
    @trusted public void toMatrix(Color[][] matrix, bool transpose) const
    in
    {
        if (transpose)
        {
            assert(matrix.length == this.height);
            assert(all!(r => r.length == this.width)(matrix));
        }
        else
        {
            assert(matrix.length == this.width);
            assert(all!(c => c.length == this.height)(matrix));
        }
    }
    do
    {
        if (transpose && this.pixelFormat == PixelFormat.Format32bppRgba)
        {
            const(void)* ptr = this.data.ptr;
            for (int y = 0; y < this.height; y++)
            {
                matrix[y][] = (cast(Color*) ptr)[this.skipX .. this.skipX + this.width];
                ptr += this.stride;
            }
        }
        else
        {
            (cast(Bitmap) this).readWrite!(true, false)((int x, int y, Color c) {
                if (transpose)
                {
                    matrix[y][x] = c;
                }
                else
                {
                    matrix[x][y] = c;
                }
            });
        }
    }

    @trusted private inout(Color[][]) auxMatrix(inout Color[] vec, bool transpose) const nothrow
    in (vec.length == this.width * this.height)
    out (result)
    {
        if (transpose)
        {
            if (transpose)
            {
                assert(result.length == this.height);
                assert(all!(r => r.length == this.width)(result));
            }
            else
            {
                assert(result.length == this.width);
                assert(all!(c => c.length == this.height)(result));
            }
        }
    }
    do
    {
        Color[][] aux;
        if (transpose)
        {
            aux = new inout(Color[])[this.height];
            for (int y = 0; y < this.height; y++)
            {
                aux[y] = cast(Color[]) vec[y * this.width .. (y + 1) * this.width];
            }
        }
        else
        {
            aux = new inout(Color[])[this.width];
            for (int x = 0; x < this.width; x++)
            {
                aux[x] = cast(Color[]) vec[x * this.height .. (x + 1) * this.height];
            }
        }
        return cast(inout(Color[])[]) aux;
    }

    /**
     * Converts the image to a vectorized matrix of color values.
     *
     * Params:
     *     matrix =
     *         The output matrix, as a vectorized array.
     *         Its length must be equal to the product between the width and height of this image.
     *   transpose =
     *         If `false`, the vectorized array scan the image column-wise.
     *         If `true`, the vectorized array scans the image row-wise.
     */
    public void toMatrix(Color[] matrix, bool transpose) const
    in (matrix.length == (cast(ulong) this.width) * this.height)
    {
        Color[][] aux = this.auxMatrix(matrix, transpose);
        this.toMatrix(aux, transpose);
    }

    /**
     * Converts the image to a matrix of color values.
     *
     * Params:
     *     transpose =
     *         If `false`, the first index in the matrix represents the X coordinate and the second index represents the Y coordinate.
     *         If `true`, the first index in the matrix represents the Y coordinate and the second index represents the X coordinate.
     *
     * Returns:
     *     The output matrix, as a "jagged" rectangular array.
     *     If `transpose` is `false`, its length is equal to the width of the image and that of each array it contains is equal to the height of the image.
     *     If `transpose` is true`, its length is equal to the height of the image and that of each array it contains is equal to the width of the image.
     */
    public Color[][] toMatrix(bool transpose) const
    out (result)
    {
        if (transpose)
        {
            assert(result.length == this.height);
            assert(all!(r => r.length == this.width)(result));
        }
        else
        {
            assert(result.length == this.width);
            assert(all!(c => c.length == this.height)(result));
        }
        for (int i = 1; i < result.length; i++)
        {
            assert(&result[i][0] - &result[i - 1][$ - 1] == 1);
        }
    }
    do
    {
        Color[] vector = new Color[this.width * this.height];
        Color[][] matrix = this.auxMatrix(vector, transpose);
        this.toMatrix(matrix, transpose);
        return matrix;
    }

    /**
     * Pastes the given matrix of color values onto the image.
     *
     * Params:
     *     matrix =
     *         The input matrix to be copied from, as a "jagged" array.
     *         If `transpose` is `false`, its length must be equal to the width of the image and that of each array it contains must be equal to the height of the image.
     *         If `transpose` is `true`, its length must be equal to the height of the image and that of each array it contains must be equal to the width of the image.
     *     transpose =
     *         If `false`, the first index in the matrix represents the X coordinate and the second index represents the Y coordinate.
     *         If `true`, the first index in the matrix represents the Y coordinate and the second index represents the X coordinate.
     */
    //@nogc
    @trusted public void fromMatrix(const Color[][] matrix, bool transpose) // nothrow
    in
    {
        if (transpose)
        {
            assert(matrix.length == this.height);
            assert(all!(r => r.length == this.width)(matrix));
        }
        else
        {
            assert(matrix.length == this.width);
            assert(all!(c => c.length == this.height)(matrix));
        }
    }
    do
    {
        if (transpose && this.pixelFormat == PixelFormat.Format32bppRgba)
        {
            void* ptr = this.data.ptr;
            for (int y = 0; y < this.height; y++)
            {
                (cast(Color*) ptr)[this.skipX .. this.skipX + this.width] = matrix[y];
                ptr += this.stride;
            }
        }
        else
        {
            this.readWrite!(false, true)((int x, int y) {
                if (transpose)
                {
                    return matrix[y][x];
                }
                else
                {
                    return matrix[x][y];
                }
            });
        }
    }

    /**
     * Pastes the given vectorized matrix of color values onto the image.
     *
     * Params:
     *     matrix =
     *         The input matrix, as a vectorized array.
     *         Its length must be equal to the product between the width and height of this image.
     *     transpose =
     *         If `false`, the vectorized array scan the image column-wise.
     *         If `true`, the vectorized array scans the image row-wise.
     */
    public void fromMatrix(const Color[] matrix, bool transpose) // nothrow
    in (matrix.length == (cast(ulong) this.width) * this.height)
    {
        const Color[][] aux = this.auxMatrix(matrix, transpose);
        this.fromMatrix(aux, transpose);
    }

    /**
     * Counts the amount of times a color appears in the image.
     *
     * Returns:
     *     An associative array of the amount of times each color appears in the image.
     *     The associative array only contains colors that appear at least once.
     *
     * Throws: If the image contains invalid values.
     */
    public size_t[Color] counts() const
    out (result; sum(result.byValue) == (cast(long) this.width) * this.height)
    {
        size_t[Color] counts;
        this.forEach((x, y, c) { counts[c]++; });
        return counts;
    }

    /**
     * Counts the amount of times each color index appears in the image.
     * The image must use an indexed color format.
     *
     * Returns:
     *     An array containing, for each entry of the color table, the amount of times it appears in the image.
     *     The array has the same lenght as the color table.
     *
     * Throws: If the image contains invalid values.
     */
    @trusted public size_t[] indexCounts() const
    in (this.indexed)
    out (result)
    {
        assert(result.length == this.palette.length);
        assert(sum(result) == (cast(long) this.width) * this.height);
    }
    do
    {
        size_t[] counts = new size_t[this.palette.length];
        counts[] = 0;
        const(void)* ptr = this.data.ptr;
        for (int y = 0; y < this.height; y++)
        {
            foreach (size_t x; this.skipX .. this.skipX + this.width)
            {
                int index;
                switch (this.pixelFormat)
                {
                case PixelFormat.Format1bppIndexed:
                    index = ((cast(ubyte*) ptr)[x / 8]) >> (7 - x % 8) & 1;
                    break;
                case PixelFormat.Format4bppIndexed:
                    index = ((cast(ubyte*) ptr)[x / 2]) >> ((1 - x % 2) * 4) & 0xF;
                    break;
                case PixelFormat.Format8bppIndexed:
                    index = (cast(ubyte*) ptr)[x];
                    break;
                default:
                    assert(0);
                }
                enforce(index < this.palette.length);
                counts[index]++;
            }
            ptr += this.stride;
        }
        return counts;
    }

    invariant
    {
        assert(this._width > 0 && this._height > 0);
        size_t mStride = minStride(this._skipX, this._width, this._pixelFormat.bpp);
        assert(mStride != 0 && this._stride >= mStride);
        assert(this._data != null);
        assert(this._data.length % this._stride == 0
                && this._data.length / this._stride == this._height);
        assert((cast(size_t)&(this._data[0])) % this._pixelFormat.alignSize == 0);
        assert(this._stride % this._pixelFormat.alignSize == 0);
        if (this._pixelFormat.indexed)
        {
            assert(this._palette != null && 1 <= this._palette.length
                    && this._palette.length <= 1 << this._pixelFormat.bpp);
        }
        else
        {
            assert(this._palette.ptr == null && this._palette.length == 0);
        }
    }
}

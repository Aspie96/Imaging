/**
 * This module provides functionalities that aren't well-suited for other modules.
 *
 * Copyright: Copyright (C) 2026 Valentino Giudice
 * License: BSL-1.0
 * Authors: [Valentino Giudice](https://www.functorfault.net/)
 */
module imaging.extra;

import imaging : Bitmap;
import std.algorithm.iteration : sum;
import std.algorithm.searching : all;
import std.array : array;
import std.exception : assumeUnique;
import std.range.primitives : isInfinite;
import std.traits : ForeachType, isArray, isFloatingPoint, isIterable, Unconst;

private struct FramesRange
{
    private Bitmap[] _frames;

    @disable this();

    @nogc @trusted private this(inout Bitmap[] frames) inout nothrow
    in
    {
        assert(frames.length > 0);
        assert(all!(bmp => bmp !is null)(frames));
        assert(all!(bmp => bmp.width == frames[0].width && bmp.height == frames[0].height)(frames));
    }
    do
    {
        this._frames = frames;
    }

    public int opApply(scope int delegate(Bitmap frame) dg)
    {
        for (size_t i = 0; i < this._frames.length; i++)
        {
            int result = dg(this._frames[i]);
            if (result != 0)
            {
                return result;
            }
        }
        return 0;
    }

    // See: https://forum.dlang.org/post/lturcepnqxtgqkjkdtkt@forum.dlang.org
    public int opApply(scope int delegate(const Bitmap frame) dg) const
    {
        for (size_t i = 0; i < this._frames.length; i++)
        {
            int result = dg(this._frames[i]);
            if (result != 0)
            {
                return result;
            }
        }
        return 0;
    }

    public int opApply(scope int delegate(immutable Bitmap frame) dg) immutable
    {
        for (size_t i = 0; i < this._frames.length; i++)
        {
            int result = dg(this._frames[i]);
            if (result != 0)
            {
                return result;
            }
        }
        return 0;
    }

    public int opApply(scope int delegate(size_t i, Bitmap frame) dg)
    {
        for (size_t i = 0; i < this._frames.length; i++)
        {
            int result = dg(i, this._frames[i]);
            if (result != 0)
            {
                return result;
            }
        }
        return 0;
    }

    public int opApply(scope int delegate(size_t i, const Bitmap frame) dg) const
    {
        for (size_t i = 0; i < this._frames.length; i++)
        {
            int result = dg(i, this._frames[i]);
            if (result != 0)
            {
                return result;
            }
        }
        return 0;
    }

    public int opApply(scope int delegate(size_t i, immutable Bitmap frame) dg) immutable
    {
        for (size_t i = 0; i < this._frames.length; i++)
        {
            int result = dg(i, this._frames[i]);
            if (result != 0)
            {
                return result;
            }
        }
        return 0;
    }

    @nogc @safe public inout(Bitmap) opIndex(size_t i) inout nothrow
    in
    {
        assert(i < this.length);
    }
    do
    {
        return this._frames[i];
    }

    /// The number of frames in the range.
    @nogc @property @safe public pure size_t length() const nothrow
    out (result; result > 0)
    {
        return this._frames.length;
    }

    public alias opDollar = length;

    invariant
    {
        assert(this._frames.length > 0);
        assert(all!(bmp => bmp !is null)(this._frames));
        assert(all!(bmp => bmp.width == this._frames[0].width && bmp.height
                == this._frames[0].height)(this._frames));
    }
}

static assert(isIterable!FramesRange && !isInfinite!FramesRange
        && is(ForeachType!FramesRange == Bitmap));
static assert(isIterable!(const FramesRange) && !isInfinite!(const FramesRange)
        && is(ForeachType!(const FramesRange) == const Bitmap));
static assert(isIterable!(immutable FramesRange) && !isInfinite!(immutable FramesRange)
        && is(ForeachType!(immutable FramesRange) == immutable Bitmap));

/**
 * Represents a frame-based animation.
 */
public class Animation
{
    private FramesRange _frames;
    private double[] _durations;
    private int _plays;

    /**
     * Creates an [Animation] object.
     *
     * Params:
     *     frames =
     *         The frames in the animation.
     *         The range must not contain null values.
     *         All frames must have the same width and height.
     *         The range is cloned, but referenced data is not.
     *     durations =
     *         The duration of each frame in the animation, in second.
     *         It must not contain negative values.
     *         The range is cloned.
     *     plays =
     *         The number of times the animations is to be played.
     *         If 0, the animation is played indefinitely.
     */
    @safe public this(R1, R2)(R1 frames, R2 durations, uint plays = 0) nothrow 
            if (isIterable!R1 && !isInfinite!R1 && is(ForeachType!R1 == Bitmap)
                && isIterable!R2 && !isInfinite!R2 && isFloatingPoint!(ForeachType!R2))
    in
    {
        assert(frames.length > 0);
        assert(durations.length == frames.length);
    }
    do
    {
        this._frames = FramesRange(array(frames));
        this._durations = cast(double[]) array(durations);
        this._plays = plays;
    }

    // See: https://github.com/dlang/dmd/issues/18575

    /// ditto
    @safe public this(R1, R2)(R1 frames, R2 durations, uint plays = 0) const nothrow
            if (isIterable!R1 && !isInfinite!R1 && is(Unconst!(ForeachType!R1) == Bitmap)
                && isIterable!R2 && !isInfinite!R2 && isFloatingPoint!(ForeachType!R2))
    in
    {
        assert(frames.length > 0);
        assert(durations.length == frames.length);
    }
    do
    {
        this._frames = const FramesRange(array(frames));
        this._durations = cast(const double[]) array(durations);
        this._plays = plays;
    }

    /// ditto
    @trusted public this(R1, R2)(R1 frames, R2 durations, uint plays = 0) immutable nothrow
            if (isIterable!R1 && !isInfinite!R1 && is(ForeachType!R1 == immutable Bitmap)
                && isIterable!R2 && !isInfinite!R2 && isFloatingPoint!(ForeachType!R2))
    in
    {
        assert(frames.length > 0);
        assert(durations.length == frames.length);
    }
    do
    {
        static if (isArray!R1)
        {
            this._frames = immutable FramesRange(frames);
        }
        else
        {
            this._frames = immutable FramesRange(assumeUnique(array(frames)));
        }
        static if (isArray!R2 && is(ForeachType!R2 == immutable ForeachType!R2))
        {
            this._durations = durations;
        }
        else
        {
            this._durations = assumeUnique(array(durations));
        }
        this._plays = plays;
    }

    /// Creating an animation from its frames
    unittest
    {
        import imaging : PixelFormat;
        import std.math.algebraic : abs;

        Bitmap[3] frames;
        frames[0] = new Bitmap(3, 3, PixelFormat.Format32bppRgba);
        frames[1] = new Bitmap(3, 3, PixelFormat.Format32bppArgb);
        frames[2] = new Bitmap(3, 3, PixelFormat.Format24bppRgb);
        Animation anim = new Animation(frames, [0.1, 0.1, 0.1]);
        assert(anim.width == 3);
        assert(anim.height == 3);
        assert(anim.durations == [0.1, 0.1, 0.1]);
        assert(abs(anim.totalDuration - 0.3) < 0.0001);
        assert(anim.length == 3);
        assert(anim.plays == 0);
        anim.plays = 2;
        assert(anim.plays == 2);
        foreach (Bitmap frame; anim.frames)
        {
            assert(frame.width == 3);
            assert(frame.height == 3);
        }
        foreach (Bitmap frame; anim.frames)
        {
            assert(frame.width == 3);
            assert(frame.height == 3);
            break;
        }
        foreach (size_t i, Bitmap frame; anim.frames)
        {
            assert(frame == frames[i]);
        }
        foreach (size_t i, Bitmap frame; anim.frames)
        {
            assert(frame == frames[i]);
            if (i > 1)
            {
                break;
            }
        }
    }

    /// The width of the frames in the animation.
    @nogc @property @safe public pure int width() const nothrow
    out (result; result > 0)
    {
        return this._frames._frames[0].width;
    }

    /// The height of the frames in the animation.
    @nogc @property @safe public pure int height() const nothrow
    out (result; result > 0)
    {
        return this.frames._frames[0].height;
    }

    /// Range of frames in the animation.
    @nogc @property @safe public auto frames() inout nothrow
    {
        return this._frames;
    }

    /// The duration of each frame in the animation, in second.
    @nogc @property @safe public inout(double[]) durations() inout nothrow
    out (result; result.length == this.length)
    {
        return this._durations;
    }

    /// The total duration of the animation.
    @nogc @property @safe public double totalDuration() const
    {
        return sum(this.durations);
    }

    /// The amount of frames in the animation.
    @nogc @property @safe public pure size_t length() const nothrow
    out (result; result > 0)
    {
        return this.frames.length;
    }

    /// The amount of times the animation is played.
    /// 0 means the animation is played indefinitely.
    @nogc @property @safe public pure uint plays() const nothrow
    {
        return this._plays;
    }

    /// ditto
    @nogc @property @safe public pure uint plays(uint plays) nothrow
    out (; this.plays == plays)
    {
        return this._plays = plays;
    }

    /**
     * Check if the animation is valid.
     *
     * Returns:
     *     `false` if the animation contain any invalid frames (a frame is invalid if it has invalid pixel values) or negative frame durations.
     *     `true` otherwise.
     */
    @nogc @safe public bool valid() const nothrow
    {
        return all!(d => d >= 0)(this.durations) && all!(bmp => bmp.valid)(this.frames._frames);
    }

    /// Checking whether an animation is valid
    unittest
    {
        import imaging : Color, PixelFormat;

        Bitmap[3] frames;
        frames[0] = new Bitmap(3, 3, PixelFormat.Format32bppRgba);
        frames[1] = new Bitmap(3, 3, PixelFormat.Format32bppArgb);
        frames[2] = new Bitmap(3, 3, PixelFormat.Format8bppIndexed, [
            Color.black, Color.white
        ]);
        frames[2].paint(Color.black);
        Animation anim = new Animation(frames, [0.1, 0.1, 0.1]);
        assert(anim.valid());
        anim.frames[2].paint(Color.white);
        anim.frames[2].palette = [Color.black];
        assert(!anim.valid());
    }

    invariant
    {
        assert(this._frames.length > 0);
        assert(this._durations.length == this._frames.length);
        assert(this._frames._frames.length > 0);
        assert(all!(bmp => bmp !is null)(this._frames._frames));
        assert(all!(bmp => bmp.width == this._frames._frames[0].width
                && bmp.height == this._frames._frames[0].height)(this._frames._frames));
    }
}

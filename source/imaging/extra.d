/**
 * This module provides functionalities that aren't well-suited for other modules.
 *
 * Copyright: Copyright (C) 2026 Valentino Giudice
 * License: BSL-1.0
 * Authors: Valentino Giudice, https://www.functorfault.net/
 */
module imaging.extra;

import imaging : Bitmap;
import std.algorithm.iteration : sum;
import std.algorithm.searching : all;

private struct FramesRange
{
    private Bitmap[] _frames;

    private @nogc @trusted this(Bitmap[] frames)
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

    public int opApply(scope int delegate(size_t i, ref const Bitmap frame) dg) const
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

    @nogc @trusted public inout(Bitmap) opIndex(size_t i) inout nothrow
    in
    {
        assert(i < this.length);
    }
    do
    {
        return this._frames[i];
    }

    /// The number of frames in the range.
    public @nogc @property @safe pure size_t length() const nothrow
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
     *         All frames must have the same width and height.
     *         The content of the array is cloned, but referenced data is not.
     *     durations =
     *         The duration of each frame in the animation, in second.
     *         It must not contain negative values.
     *         The content of the array is cloned.
     *     plays =
     *         The number of times the animations is to be played.
     *         If 0, the animation is played indefinitely.
     */
    @safe public this(Bitmap[] frames, const double[] durations, uint plays = 0)
    in
    {
        assert(frames.length > 0);
        assert(durations.length == frames.length);
        assert(all!(bmp => bmp !is null)(frames));
        assert(all!(bmp => bmp.width == frames[0].width && bmp.height == frames[0].height)(frames));
    }
    do
    {
        this._frames = FramesRange(frames);
        this._durations = durations.dup;
        this._plays = plays;
    }

    /// The width of the frames in the animation.
    @nogc @property @safe public pure int width() const nothrow
    {
        return this._frames._frames[0].width;
    }

    /// The height of the frames in the animation.
    @nogc @property @safe public pure int height() const nothrow
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
    {
        return this.frames.length;
    }

    /// The amount of times the animation is played.
    /// O means the animation is played indefinitely.
    @nogc @property @safe public pure uint plays() const nothrow
    {
        return this._plays;
    }

    /// ditto
    @nogc @property @safe public pure uint plays(uint plays) nothrow
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

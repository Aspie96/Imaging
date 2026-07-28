module examples.display;

import imaging : Bitmap, Color, PixelFormat;
import imaging.extra : Animation;
import imaging.files : AnimatedImageFormat, AnimatedImageLoader, ImageFormat,
    ImageLoader, LoadState, SingleImageFormat;
import std.algorithm.iteration : map;
import std.array : array;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.digest.sha : sha256Of;
import std.file : dirEntries, DirEntry, remove, SpanMode;
import std.stdio : File, write, writefln, writeln;
import std.string : toStringz;

extern (C)
{
    uint* get_buffer();
    void init_buffer(int width, int height);
    int create_window(const char* title, int width, int height);
    int event_loop();
}

Bitmap readImage(string fname)
{
    File fp = File(fname, "rb");
    SingleImageFormat format = SingleImageFormat.format(fp);
    ImageLoader loader = format.loader(fp);
    Bitmap img = loader.nextImage();
    assert(loader.state == LoadState.End);
    assert(!fp.eof && fp.tell == fp.size);
    fp.close();
    return img;
}

void main()
{
    Bitmap bmp = readImage("images/peppers.png");

    init_buffer(bmp.width, bmp.height);
    uint* buffer = get_buffer();
    Bitmap bmp1 = new Bitmap(bmp.width, bmp.height, 0, bmp.width * 4,
            PixelFormat.Format32bppArgb, null, false, buffer[0 .. bmp.width * bmp.height]);
    bmp1.copyFrom(bmp);

    const char* title = "my window".toStringz();
    int err = create_window(title, 512, 512);
    assert(err == 0);

    while (event_loop())
    {
    }
}

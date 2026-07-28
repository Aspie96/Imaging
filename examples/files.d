import imaging : Bitmap;
import imaging.extra : Animation;
import imaging.files : AnimatedImageFormat, AnimatedImageLoader, ImageFormat,
    ImageLoader, LoadState, SingleImageFormat;
import imaging.files.apng : ApngFormat;
import imaging.files.png : PngFormat;
import std.algorithm.iteration : map;
import std.array : array;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.digest.sha : sha256Of;
import std.file : dirEntries, DirEntry, remove, SpanMode;
import std.stdio : File, write, writefln, writeln;

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

Animation readAnimation(string fname)
{
    File fp = File(fname, "rb");
    AnimatedImageFormat format = AnimatedImageFormat.format(fp);
    AnimatedImageLoader loader = format.loader(fp);
    Animation anim = loader.wholeAnimation();
    assert(loader.state == LoadState.End);
    assert(!fp.eof && fp.tell == fp.size);
    fp.close();
    return anim;
}

void main()
{
    writeln("Imaging library \"files\" example");

    StopWatch sw = StopWatch(AutoStart.no);
    write("Testing good BMP files...");
    sw.start();
    auto bmpTests = dirEntries("images/bmpsuite/g", "*.bmp", SpanMode.shallow);
    foreach (string fname; bmpTests)
    {
        Bitmap img1 = readImage(fname);
        File fp = File("tmp.bmp", "wb");
        ImageFormat.bmp.save(fp, img1);
        fp.close();
        Bitmap img2 = readImage("tmp.bmp");
        assert(img2.equals(img1));
    }
    sw.stop();
    writefln(" done (%d ms)!", sw.peek().total!"msecs");
    remove("tmp.bmp");

    sw.reset();
    write("Testing questionable BMP files...");
    sw.start();
    auto bmpQuestionableTests = map!(s => "images/bmpsuite/q/" ~ s)([
        "pal1p1.bmp", "pal2.bmp", "pal2color.bmp", "pal8offs.bmp",
        "pal8os2sp.bmp", "pal8os2-sz.bmp", "pal8os2v2-40sz.bmp",
        "pal8oversizepal.bmp", "rgb16-231.bmp", "rgb16-3103.bmp",
        "rgb16faketrns.bmp", "rgb24largepal.bmp", "rgb24png.bmp", "rgb32-7187.bmp",
        "rgb32-111110.bmp", "rgb32fakealpha.bmp", "rgb32-xbgr.bmp"
    ]);
    foreach (string fname; bmpQuestionableTests)
    {
        Bitmap img1 = readImage(fname);
        File fp = File("tmp.bmp", "wb");
        ImageFormat.bmp.save(fp, img1);
        fp.close();
        Bitmap img2 = readImage("tmp.bmp");
        assert(img2.equals(img1));
    }
    sw.stop();
    writefln(" done (%d ms)!", sw.peek().total!"msecs");
    remove("tmp.bmp");

    sw.reset();
    write("Testing bad BMP files...");
    sw.start();
    auto bmpBadTests = dirEntries("images/bmpsuite/b", "*.bmp", SpanMode.shallow);
    foreach (string fname; bmpBadTests)
    {
        File fp = File(fname, "rb");
        ImageLoader loader = ImageFormat.bmp.loader(fp);
        if (loader.state != LoadState.Invalid)
        {
            loader.nextImage();
            assert(loader.state == LoadState.Invalid);
        }
        fp.close();
    }
    sw.stop();
    writefln(" done (%d ms)!", sw.peek().total!"msecs");

    sw.reset();
    write("Testing QOI files...");
    sw.start();
    auto qoiTests = dirEntries("images/qoi_test_images", "*.qoi", SpanMode.shallow);
    foreach (string fname; qoiTests)
    {
        Bitmap img1 = readImage(fname);
        Bitmap img2 = readImage(fname[0 .. $ - 3] ~ "png");
        assert(img2.equals(img1));
        File fp = File("tmp.qoi", "wb");
        ImageFormat.qoi.save(fp, img1, img1.bpp == 32);
        fp.close();
        fp = File(fname, "rb");
        auto hash1 = sha256Of(fp.byChunk(4096 * 1024));
        fp.close();
        fp = File("tmp.qoi", "rb");
        auto hash2 = sha256Of(fp.byChunk(4096 * 1024));
        fp.close();
        assert(hash1 == hash2);
    }
    sw.stop();
    writefln(" done (%d ms)!", sw.peek().total!"msecs");
    remove("tmp.qoi");

    sw.reset();
    write("Testing PNG files...");
    sw.start();
    auto pngTests = dirEntries("images/PngSuite", "*.png", SpanMode.shallow);
    foreach (string fname; pngTests)
    {
        File fp = File(fname, "rb");
        ImageFormat format = ImageFormat.format(fp);
        if (fname["images/PngSuite".length + 1] == 'x')
        {
            assert(format is PngFormat.instance() || format is null);
            ImageLoader loader = ImageFormat.png.loader(fp);
            loader.nextImage();
            fp.close();
            assert(loader.state == LoadState.Invalid);
        }
        else
        {
            assert(format is PngFormat.instance());
            fp.close();
            Bitmap img1 = readImage(fname);
            fp = File("tmp.png", "wb");
            ImageFormat.png.save(fp, img1);
            fp.close();
            Bitmap img2 = readImage("tmp.png");
            assert(img2.equals(img1));
        }
    }
    sw.stop();
    writefln(" done (%d ms)!", sw.peek().total!"msecs");
    remove("tmp.png");

    DirEntry[] apngTests = array(dirEntries("images/apng", "*.png", SpanMode.shallow));
    DirEntry[] validApngTests = apngTests[0 .. 39];
    DirEntry[] badApngTests = apngTests[39 .. $];

    sw.reset();
    write("Testing valid APNG files...");
    sw.start();
    foreach (string fname; validApngTests)
    {
        File fp = File(fname, "rb");
        ImageFormat format = ImageFormat.format(fp);
        fp.close();
        string baseName = fname[$ - 7 .. $];
        if (baseName == "000.png" || baseName == "003.png" || baseName == "004.png")
        {
            assert(format is PngFormat.instance());
        }
        else
        {
            assert(format is ApngFormat.instance());
        }
        Animation anim1 = readAnimation(fname);
        fp = File("tmp.apng", "wb");
        ImageFormat.apng.save(fp, anim1);
        fp.close();
        Animation anim2 = readAnimation("tmp.apng");
        assert(anim2.length == anim1.length);
        for (int i = 0; i < anim1.length; i++)
        {
            assert(anim2.frames[i].equals(anim1.frames[i]));
        }
    }
    sw.stop();
    writefln(" done (%d ms)!", sw.peek().total!"msecs");
    remove("tmp.apng");

    sw.reset();
    write("Testing invalid APNG files...");
    sw.start();
    foreach (string fname; badApngTests)
    {
        File fp = File(fname, "rb");
        ImageFormat format = ImageFormat.format(fp);
        string baseName = fname[$ - 7 .. $];
        if (baseName == "039.png" || baseName == "041.png")
        {
            assert(format is PngFormat.instance());
        }
        else
        {
            assert(format is ApngFormat.instance());
        }
        AnimatedImageLoader loader = AnimatedImageFormat.apng.loader(fp);
        if (loader.state != LoadState.Invalid)
        {
            loader.wholeAnimation();
            assert(loader.state == LoadState.Invalid);
        }
        fp.close();
    }
    sw.stop();
    writefln(" done (%d ms)!", sw.peek().total!"msecs");
}

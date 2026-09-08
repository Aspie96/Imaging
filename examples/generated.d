import imaging : Bitmap, Color, flipEndian, PixelFormat, Rectangle;
import imaging.files : ImageFormat, ImageLoader, LoadState, MultiImageFormat, SingleImageFormat;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.exception : assumeUnique;
import std.math : PI;
import std.math.algebraic : hypot, sqrt;
import std.math.exponential : log;
import std.math.rounding : floor, round;
import std.math.trigonometry : atan2;
import std.stdio : File, stdout, write, writefln, writeln;

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

Bitmap[] readMultipleImages(string fname)
{
    File fp = File(fname, "rb");
    MultiImageFormat format = MultiImageFormat.format(fp);
    ImageLoader loader = format.loader(fp);
    Bitmap[] images = [];
    do
    {
        Bitmap img = loader.nextImage();
        assert(loader.state == LoadState.BeforeInfo || loader.state == LoadState.End);
        images ~= img;
    }
    while (loader.state != LoadState.End);
    assert(!fp.eof && fp.tell == fp.size);
    fp.close();
    return images;
}

Color fromHue(float hue)
{
    hue = ((hue % 1) + 1) % 1;
    float r;
    float g;
    float b;
    int i = cast(int) floor(hue * 6);
    float f = hue * 6 - i;
    final switch (i)
    {
    case 0:
        r = 1;
        g = f;
        b = 0;
        break;
    case 1:
        r = (1 - f);
        g = 1;
        b = 0;
        break;
    case 2:
        r = 0;
        g = 1;
        b = f;
        break;
    case 3:
        r = 0;
        g = (1 - f);
        b = 1;
        break;
    case 4:
        r = f;
        g = 0;
        b = 1;
        break;
    case 5:
        r = 1;
        g = 0;
        b = (1 - f);
        break;
    }
    return Color(cast(ubyte) round(r * 255), cast(ubyte) round(g * 255), cast(ubyte) round(b * 255));
}

void main()
{
    writeln("Imaging library \"generated\" example");

    StopWatch sw = StopWatch(AutoStart.no);
    write("Generating \"dman-colors.bmp\"... ");
    stdout.flush();
    sw.start();
    Bitmap dmanImg = readImage("images/d3.png");
    Color[] dPalette = [Color(0, 0, 0, 0), Color.black, Color.white, Color.d];
    Bitmap palettized = new Bitmap(dmanImg.width, dmanImg.height,
            PixelFormat.Format4bppIndexed, assumeUnique(dPalette[]));
    palettized.copyFrom(dmanImg);
    Bitmap colorful = new Bitmap(dmanImg.width, dmanImg.height, PixelFormat.Format24bppRgbBE);
    for (int y = 0; y < colorful.height; y++)
    {
        Color color = fromHue((cast(float) y) / colorful.height);
        (cast(ubyte[3][]) colorful.data)[y * colorful.width .. (y + 1) * colorful.width] = [
            color.r, color.g, color.b
        ];
    }
    Bitmap result = new Bitmap(dmanImg.width, dmanImg.height, PixelFormat.Format24bppRgb);
    result.paint((x, y) {
        Color color = palettized.getPixel(x, y);
        if (color.a == 0)
        {
            color = colorful.getPixel(x, y);
        }
        return color;
    });
    File fp = File("dman-colors.bmp", "wb");
    ImageFormat.bmp.save(fp, result);
    fp.close();
    sw.stop();
    writefln("Done (%d ms)!", sw.peek().total!"msecs");

    sw.reset();
    write("Generating \"dman-pop.bmp\"... ");
    stdout.flush();
    sw.start();
    Bitmap popArt = new Bitmap(dmanImg.width * 3, dmanImg.height * 2, PixelFormat.Format24bppRgb);
    Bitmap palettized1 = new Bitmap(dmanImg.width, dmanImg.height, 0, palettized.stride,
            PixelFormat.Format4bppIndexed, assumeUnique(dPalette[]), false, palettized.data);
    Color[4][] palettes = [
        [Color.red, Color.green, Color.blue, Color.black],
        [Color.white, Color.red, Color.green, Color.blue],
        [Color.cyan, Color.magenta, Color.yellow, Color.white],
        [Color.black, Color.cyan, Color.magenta, Color.yellow],
        [Color.d, Color.white, Color.black, Color.gray(127)],
        [Color.gray(127), Color.d, Color.white, Color.black]
    ];
    int index = 0;
    for (int y = 0; y < 2; y++)
    {
        for (int x = 0; x < 3; x++)
        {
            Bitmap slice = popArt.slice(Rectangle(x * dmanImg.width,
                    y * dmanImg.height, dmanImg.width, dmanImg.height));
            palettized1.palette = assumeUnique(palettes[index][]);
            slice.copyFrom(palettized1);
            index++;
        }
    }
    fp = File("dman-pop.bmp", "wb");
    ImageFormat.bmp.save(fp, popArt);
    fp.close();
    sw.stop();
    writefln("Done (%d ms)!", sw.peek().total!"msecs");

    sw.reset();
    write("Generating \"generated1.bmp\"... ");
    stdout.flush();
    sw.start();
    Bitmap generated1 = new Bitmap(256, 256, PixelFormat.Format24bppRgb);
    generated1.paint((x, y) {
        float xf = (x + 0.5F) / 256;
        float yf = (y + 0.5F) / 256;
        xf = (xf - 0.5F) * 2;
        yf = (yf - 0.5F) * 2;
        float angle = atan2(xf, yf);
        angle /= PI;
        angle = ((angle + 1) * 6) % 2 - 1;
        float factor = sqrt(1 - (angle * angle)) * 5;
        float hue = hypot(xf, yf) * factor;
        return fromHue(hue);
    });
    fp = File("generated1.bmp", "wb");
    ImageFormat.bmp.save(fp, generated1);
    fp.close();
    sw.stop();
    writefln("Done (%d ms)!", sw.peek().total!"msecs");

    sw.reset();
    write("Generating \"generated2.bmp\"... ");
    stdout.flush();
    sw.start();
    Bitmap generated2 = new Bitmap(256, 256, PixelFormat.Format24bppRgb);
    generated2.paint((x, y) {
        float xf = (x + 0.5F) / 256;
        float yf = (y + 0.5F) / 256;
        xf = (xf - 0.5F) * 2;
        yf = (yf - 0.5F) * 2;
        float angle = atan2(xf, yf);
        angle = (angle / PI - 1) / 2;
        float distance = hypot(xf, yf);
        float phase = log(distance) * 0.7F;
        angle += phase;
        return fromHue(angle);
    });
    fp = File("generated2.bmp", "wb");
    ImageFormat.bmp.save(fp, generated2);
    fp.close();
    sw.stop();
    writefln("Done (%d ms)!", sw.peek().total!"msecs");

    Bitmap img1 = new Bitmap(2, 2, PixelFormat.Format32bppRgba);
    img1.setPixel(0, 0, Color.red);
    img1.setPixel(1, 0, Color.green);
    img1.setPixel(0, 1, Color.blue);
    img1.setPixel(1, 1, Color.black);
    PixelFormat[] testFormats = [
        PixelFormat.Format32bppRgba, PixelFormat.Format32bppArgb,
        flipEndian(PixelFormat.Format32bppRgba),
        PixelFormat.Format24bppRgbBE, PixelFormat.Format24bppRgbLE
    ];
    foreach (PixelFormat pixelFormat; testFormats)
    {
        Bitmap img2 = new Bitmap(2, 2, pixelFormat);
        img2.from(img1, false, false, false);
        assert(img2.getPixel(0, 0) == Color.red);
        assert(img2.getPixel(1, 0) == Color.green);
        assert(img2.getPixel(0, 1) == Color.blue);
        assert(img2.getPixel(1, 1) == Color.black);
        img2.from(img1, true, false, false);
        assert(img2.getPixel(0, 0) == Color.red);
        assert(img2.getPixel(1, 0) == Color.blue);
        assert(img2.getPixel(0, 1) == Color.green);
        assert(img2.getPixel(1, 1) == Color.black);
        img2.from(img1, false, true, true);
        assert(img2.getPixel(0, 0) == Color.black);
        assert(img2.getPixel(1, 0) == Color.blue);
        assert(img2.getPixel(0, 1) == Color.green);
        assert(img2.getPixel(1, 1) == Color.red);
    }
}

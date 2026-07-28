# Imaging

This directory is part of the Imaging project. See the [root](../) of this project.

## Examples

This directory contains three examples for the Imaging library.

The contents of the [`images`](./images) directory need to be cloned from the designated [repository](https://github.com/Aspie96/Imaging-exsample-images). This is so as to spare mere users of the library from downloading test images.

All examples are compiled to an executable named `example`. Each example corresponds to a different DUB configuration. See the [`dub.sdl`](./dub.sdl) recipe file.

### `files`

In this example, images are imported and exported from and to all supported formats, to test for this capability.

### `generated`

In this example, images are generated and exported to files.

### `display`

In this example, an image is shown on the screen.

This cross-platform example is based on the *[Cross-platform window in C](https://imadrahmoune.com/cross-platform-window-in-c/)* article by Imad and uses the [`window.h`](./window.h) file straight from its [source](https://github.com/imadr/cross-platform-window/blob/main/src/window.h) without modifications. The file doesn't have a license and an [issue](https://github.com/imadr/cross-platform-window/issues/1) has been opened on the matter.

On Windows, the [`window.c`](./window.c) file needs to be compiled without linking as `window.obj` before building the D package. To do so, open the Developer Command Prompt for Visual Studio in this directory and write:

```
cl window.c /c
```

## Example images

The images and collections in (the repository for) the [`images`](./images/) directory are third party assets and have been sourced as follows:

- The [`images/apng`](./images/apng/) directory contains all examples from the [APNG tests](https://philip.html5.org/tests/apng/tests.html) page.
- The [`images/bmpsuite`](./images/bmpsuite/) directory is from [BMP Suite](https://entropymine.com/jason/bmpsuite/), version 2.8. While the program that generates these images is under the GNU GPL, version 3 or later, the images themselves are expressly in the public domain.
- The [`images/PngSuite`](./images/PngSuite/) directory is from [PngSuite](http://schaik.com/pngsuite/) by Willem van Schaik.
- The [`images/qoi_test_images`](./images/qoi_test_images/) directory is from the [Quite OK Image Format](https://qoiformat.org/) website by Dominic Szablewski.
- The [`d3.png`](./d3.png) image and the corresponding [`dlogo.svg`](./dlogo.svg) vectorized version display D-Man, the mascot of the D programming language.
- The [`peppers.png`](./peppers.png) image is [from](https://github.com/imadr/cross-platform-window/blob/main/src/peppers.png) the referenced cross-platforming window example.

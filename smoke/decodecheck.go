// Two checks the shell cannot do:
//
//	decodecheck <file>              exits non-zero unless Go's stdlib
//	                                decoders accept the image; the
//	                                normalize step exists so this exact
//	                                decode succeeds on its output.
//	decodecheck -similar <a> <b>    exits non-zero when the two images
//	                                do not show the same content. Guards
//	                                the scale path: a broken scaler can
//	                                emit a structurally valid JPEG full
//	                                of garbage rows, which magic-byte
//	                                checks wave through.
package main

import (
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"os"
)

func decode(path string) image.Image {
	f, err := os.Open(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer f.Close()
	img, _, err := image.Decode(f)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)
		os.Exit(1)
	}
	return img
}

// meanAbsDiff samples both images on a common grid (nearest neighbor)
// and returns the mean absolute per-channel difference in 8-bit units.
func meanAbsDiff(a, b image.Image) float64 {
	const grid = 64
	ab, bb := a.Bounds(), b.Bounds()
	var sum, n float64
	for y := 0; y < grid; y++ {
		for x := 0; x < grid; x++ {
			ar, ag, abl, _ := a.At(ab.Min.X+x*ab.Dx()/grid, ab.Min.Y+y*ab.Dy()/grid).RGBA()
			br, bg, bbl, _ := b.At(bb.Min.X+x*bb.Dx()/grid, bb.Min.Y+y*bb.Dy()/grid).RGBA()
			d := func(p, q uint32) float64 {
				if p > q {
					return float64(p-q) / 257
				}
				return float64(q-p) / 257
			}
			sum += d(ar, br) + d(ag, bg) + d(abl, bbl)
			n += 3
		}
	}
	return sum / n
}

func main() {
	if len(os.Args) == 4 && os.Args[1] == "-similar" {
		diff := meanAbsDiff(decode(os.Args[2]), decode(os.Args[3]))
		fmt.Printf("mean abs diff %.1f\n", diff)
		if diff > 40 {
			os.Exit(1)
		}
		return
	}
	f, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer f.Close()
	cfg, format, err := image.DecodeConfig(f)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("%s %dx%d\n", format, cfg.Width, cfg.Height)
}

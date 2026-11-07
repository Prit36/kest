# Response decoder fixtures

These synthetic fixtures are embedded only in diagnostic executables.

- `preview-large.png`: 3000 x 1600 checkerboard. Exercises CPU decode and
  reduction to a 2048 x 1092 preview while preserving the original bytes.
- `preview.jpg`: 96 x 48 solid orange JPEG. Exercises the real JPEG decoder.
- `expansion-invalid.png`: a valid PNG envelope with a 1 x 1 RGBA header whose
  IDAT expands to 256 MiB. It is intentionally invalid. The decoder allocation
  budget must reject it before materializing that data.

Run `python tests/fixtures/response/generate.py` to reproduce the files. Pillow
is needed only to regenerate the ordinary images; builds/tests use embedded
bytes and do not need Python or Pillow.

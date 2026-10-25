# Lightbox

A small macOS photo tool built on the [Borderless](https://github.com/stormbuster/borderless) window: drop a photo anywhere on the
window and a floating **Tools** panel offers AI background removal and AI upscaling. Everything runs locally through Core ML on
Apple silicon (GPU + Neural Engine). The app is sandboxed without network access, so photos never leave the Mac.

## Models

| Task | Model | Licence | Runs on | Speed (M5 Pro) |
|---|---|---|---|---|
| Background, default | [BiRefNet_HR](https://huggingface.co/ZhengPeng7/BiRefNet_HR), 2048 px | MIT | GPU | ~1.4 s per photo |
| Background, hair/fur/glass | [BiRefNet_HR-matting](https://huggingface.co/ZhengPeng7/BiRefNet_HR-matting), 2048 px | MIT | GPU | ~1.4 s |
| Upscale "Restore" (default for JPEG/HEIC) | [4xBHI_dat2_real](https://github.com/Phhofm/models/releases/tag/4xBHI_dat2_real) | CC-BY-4.0 | GPU | ~10 s per input MP |
| Upscale "Faithful" (default for RAW/TIFF/PNG) | [4xNomos2_hq_dat2](https://github.com/Phhofm/models/releases/tag/4xNomos2_hq_dat2) | CC-BY-4.0 | GPU | ~10 s per input MP |
| Upscale "Fast" | [Real-ESRGAN x4plus](https://github.com/xinntao/Real-ESRGAN) | BSD-3 | Neural Engine | ~2.5 s per input MP |

Why these: BiRefNet is the state-of-the-art open model for high-resolution dichotomous segmentation; Bria RMBG-2.0 is the same
architecture trained by Bria but CC BY-NC (non-commercial), so it was left out. DAT2 transformers give the most faithful photo detail;
the BHI variant is trained on real degradations (JPEG/WebP compression, noise, blur), Nomos2-hq on clean images (it reproduces JPEG
blocks on compressed input). 2× and 3× run the 4× model and resample each tile with Lanczos.

Upscaling a cutout upscales the colour with the AI model and the alpha matte with a smooth resampler, so edges stay clean.
Exports keep EXIF/GPS/IPTC metadata; JPEG exports of cutouts are flattened on white.

## Building

```sh
tools/build-models.sh          # downloads the official weights and converts them to Lightbox/Models/*.mlpackage (~1.3 GB)
xcodegen generate
xcodebuild -scheme Lightbox -configuration Release -derivedDataPath build build
```

Conversion notes (`tools/`):
- BiRefNet's decoder uses `torchvision.ops.deform_conv2d`, which Core ML lacks. `convert_birefnet.py` swaps in an exact
  equivalent built from `grid_sample` + per-tap 1×1 convolutions (max error 7e-5 vs torchvision); the Core ML matte matches
  PyTorch at IoU 0.9994 and is ~4× faster than PyTorch on MPS.
- `ct_patches.py` fixes a coremltools cast error on traced shape arithmetic (DAT, BiRefNet).
- DAT2's window attention is ~150× slower on the Neural Engine than the GPU, so the DAT2 models are pinned to CPU+GPU.
- `check_upscaler.py` / `check_birefnet.py` compare the Core ML output with PyTorch and time each compute unit.

Debug builds accept `--selftest <photo>` (runs every model headless, writes results next to the photo inside the app container)
and `--snapshot <dir>` (writes PNGs of the windows after 10 s).

"""Convert a spandrel-loadable 4x upscaler (.pth/.safetensors) to a fixed-tile Core ML model.

Input  "image": RGB image, TILE x TILE.   Output "upscaled": RGB image, 4*TILE x 4*TILE.
The app tiles larger photos with overlap. Usage: convert_upscaler.py <weights> <out.mlpackage> [tile]
"""
import sys, time
import numpy as np, torch, coremltools as ct
from spandrel import ModelLoader
import ct_patches  # noqa: F401


class Wrapper(torch.nn.Module):
    def __init__(self, net):
        super().__init__(); self.net = net
    def forward(self, x):                      # x in 0..1 (ImageType scale 1/255)
        return (self.net(x).clamp(0, 1) * 255.0)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    tile = int(sys.argv[3]) if len(sys.argv) > 3 else 256
    desc = ModelLoader().load_from_file(src)
    print("arch", desc.architecture.name, "scale", desc.scale)
    net = Wrapper(desc.model.eval().float())
    x = torch.rand(1, 3, tile, tile)
    with torch.no_grad():
        traced = torch.jit.trace(net, x, check_trace=False)
    t = time.time()
    ml = ct.convert(traced, inputs=[ct.ImageType(name="image", shape=x.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
                    outputs=[ct.ImageType(name="upscaled", color_layout=ct.colorlayout.RGB)],
                    minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16)
    ml.short_description = f"{desc.architecture.name} {desc.scale}x upscaler, {tile}px tiles"
    ml.save(dst); print("converted in", round(time.time() - t), "s ->", dst)


if __name__ == "__main__":
    main()

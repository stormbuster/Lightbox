"""Convert BiRefNet (official ZhengPeng7 weights) to Core ML.

torchvision's deform_conv2d has no Core ML op, so it is replaced by an exact equivalent built from grid_sample
(bilinear, zero padding) plus one 1x1 conv per kernel tap. The model's ImageNet normalisation and the final sigmoid
are folded in: input "image" is RGB SIZE x SIZE, output "mask" is an 8-bit-range grayscale alpha matte.
Usage: convert_birefnet.py <hf_dir> <out.mlpackage> <size> [--check]
"""
import sys, time
import numpy as np, torch, torch.nn.functional as F, coremltools as ct
from transformers import AutoModelForImageSegmentation
import ct_patches  # noqa: F401


def deform_conv2d(input, offset, weight, bias=None, stride=(1, 1), padding=(0, 0), dilation=(1, 1), mask=None):
    st = stride if isinstance(stride, tuple) else (stride, stride)
    pd = padding if isinstance(padding, tuple) else (padding, padding)
    assert st == (1, 1), "only stride 1 is used by BiRefNet"
    b, c, h, w = input.shape
    o, _, kh, kw = weight.shape
    ys = torch.arange(h, dtype=input.dtype, device=input.device).view(1, h, 1)
    xs = torch.arange(w, dtype=input.dtype, device=input.device).view(1, 1, w)
    out = 0
    for i in range(kh):
        for j in range(kw):
            k = i * kw + j
            py = ys + (i - pd[0]) + offset[:, 2 * k]          # torchvision layout: (dy, dx) per tap
            px = xs + (j - pd[1]) + offset[:, 2 * k + 1]
            grid = torch.stack((2 * px / (w - 1) - 1, 2 * py / (h - 1) - 1), dim=-1)
            s = F.grid_sample(input, grid, mode="bilinear", padding_mode="zeros", align_corners=True)
            if mask is not None:
                s = s * mask[:, k:k + 1]
            out = out + F.conv2d(s, weight[:, :, i:i + 1, j:j + 1])
    return out if bias is None else out + bias.view(1, -1, 1, 1)


class Wrapper(torch.nn.Module):
    def __init__(self, net):
        super().__init__(); self.net = net
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))
    def forward(self, x):                          # x in 0..1
        return torch.sigmoid(self.net((x - self.mean) / self.std)[-1]) * 255.0


def check_deform():
    from torchvision.ops import deform_conv2d as ref
    torch.manual_seed(0)
    for k in (1, 3, 7):
        x = torch.randn(1, 8, 20, 24); off = torch.randn(1, 2 * k * k, 20, 24) * 2
        m = torch.rand(1, k * k, 20, 24) * 2; wt = torch.randn(5, 8, k, k); bs = torch.randn(5)
        a = ref(x, off, wt, bs, padding=(k // 2, k // 2), mask=m)
        b = deform_conv2d(x, off, wt, bs, padding=(k // 2, k // 2), mask=m)
        print(f"deform k={k}: max abs diff {float((a - b).abs().max()):.2e}")


def main():
    src, dst, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
    if "--check" in sys.argv:
        check_deform()
    model = AutoModelForImageSegmentation.from_pretrained(src, trust_remote_code=True).eval().float()
    sys.modules[type(model).__module__].deform_conv2d = deform_conv2d
    net = Wrapper(model).eval()
    x = torch.rand(1, 3, size, size)
    with torch.no_grad():
        traced = torch.jit.trace(net, x, check_trace=False)
    t = time.time()
    ml = ct.convert(traced, inputs=[ct.ImageType(name="image", shape=x.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
                    outputs=[ct.ImageType(name="mask", color_layout=ct.colorlayout.GRAYSCALE)],
                    minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16)
    ml.short_description = f"BiRefNet ({src.rstrip('/').split('/')[-1]}) background matte, {size}px"
    ml.save(dst); print("converted in", round(time.time() - t), "s ->", dst)


if __name__ == "__main__":
    main()

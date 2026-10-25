"""Convert ViTMatte (hustvl, Apache-2.0) to Core ML for trimap-based hair/edge matting.

Inputs: "image" RGB SIZE x SIZE, "trimap" grayscale SIZE x SIZE (0 = background, 128 = unknown, 255 = foreground).
Output: "alpha" grayscale matte. Normalisation (mean/std 0.5) is folded in.
Usage: convert_vitmatte.py <hf_repo_or_dir> <out.mlpackage> [size] [--check <photo>]
"""
import sys, time
import numpy as np, torch, coremltools as ct
from transformers import VitMatteForImageMatting
import ct_patches  # noqa: F401


from transformers.models.vitdet import modeling_vitdet

_get_abs = modeling_vitdet.VitDetEmbeddings.get_absolute_positions


def _constant_positions(self, abs_pos_embeddings, has_cls_token, height, width):
    """ViTDet bicubic-resizes its learned position table to the token grid. At a fixed input size that is a constant,
    so compute it eagerly and hand the tracer a constant (Core ML has no bicubic upsample op)."""
    with torch.no_grad():
        out = _get_abs(self, abs_pos_embeddings.detach(), has_cls_token, height, width)
    return torch.from_numpy(out.detach().cpu().numpy().copy())


modeling_vitdet.VitDetEmbeddings.get_absolute_positions = _constant_positions

_get_rel_pos = modeling_vitdet.get_rel_pos.__wrapped__ if hasattr(modeling_vitdet.get_rel_pos, "__wrapped__") else None


def _constant_rel_pos(q_size, k_size, rel_pos):
    """Same story for the relative-position tables (scripted upstream so sizes can vary): constant at a fixed size."""
    import torch.nn.functional as F
    with torch.no_grad():
        max_rel_dist = int(2 * max(q_size, k_size) - 1)
        table = rel_pos.detach()
        if table.shape[0] != max_rel_dist:
            table = F.interpolate(table.reshape(1, table.shape[0], -1).permute(0, 2, 1), size=max_rel_dist, mode="linear")
            table = table.reshape(-1, max_rel_dist).permute(1, 0)
        q = torch.arange(q_size)[:, None] * max(k_size / q_size, 1.0)
        k = torch.arange(k_size)[None, :] * max(q_size / k_size, 1.0)
        coords = (q - k) + (k_size - 1) * max(q_size / k_size, 1.0)
        out = table[coords.long()]
    return torch.from_numpy(out.cpu().numpy().copy())


modeling_vitdet.get_rel_pos = _constant_rel_pos


class Wrapper(torch.nn.Module):
    def __init__(self, net):
        super().__init__(); self.net = net
    def forward(self, image, trimap):              # both in 0..1
        x = torch.cat([(image - 0.5) / 0.5, trimap], dim=1)
        return self.net(pixel_values=x).alphas.clamp(0, 1) * 255.0


def main():
    src, dst = sys.argv[1], sys.argv[2]
    size = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else 1024
    net = Wrapper(VitMatteForImageMatting.from_pretrained(src).eval().float()).eval()
    img, tri = torch.rand(1, 3, size, size), torch.rand(1, 1, size, size)
    with torch.no_grad():
        traced = torch.jit.trace(net, (img, tri), check_trace=False)
    t = time.time()
    ml = ct.convert(traced, inputs=[
        ct.ImageType(name="image", shape=img.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB),
        ct.ImageType(name="trimap", shape=tri.shape, scale=1 / 255.0, color_layout=ct.colorlayout.GRAYSCALE)],
        outputs=[ct.ImageType(name="alpha", color_layout=ct.colorlayout.GRAYSCALE)],
        minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16)
    ml.short_description = f"ViTMatte trimap matting, {size}px"
    ml.save(dst); print("converted in", round(time.time() - t), "s ->", dst)

    if "--check" in sys.argv:                       # compare with PyTorch on a crop of a real photo
        from PIL import Image
        photo = Image.open(sys.argv[sys.argv.index("--check") + 1]).convert("RGB").resize((size, size))
        trimap = Image.new("L", (size, size), 0); trimap.paste(128, (size // 4, 0, size // 2, size)); trimap.paste(255, (size // 2, 0, size, size))
        x = torch.from_numpy(np.array(photo)).permute(2, 0, 1)[None].float() / 255
        tr = torch.from_numpy(np.array(trimap))[None, None].float() / 255
        with torch.no_grad():
            ref = net(x, tr)[0, 0].numpy()
        for cu in ["CPU_AND_GPU", "ALL"]:
            m = ct.models.MLModel(dst, compute_units=getattr(ct.ComputeUnit, cu))
            m.predict({"image": photo, "trimap": trimap})
            t = time.time(); out = np.asarray(m.predict({"image": photo, "trimap": trimap})["alpha"]).astype(np.float32)
            print(f"{cu}: {time.time() - t:.2f}s, mean|diff| vs torch {np.abs(out - ref).mean():.2f}/255")


if __name__ == "__main__":
    main()

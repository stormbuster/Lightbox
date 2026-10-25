"""Compare a converted upscaler with its PyTorch original on one 256 crop; time each compute unit."""
import sys, time, numpy as np, torch, coremltools as ct
from PIL import Image
from spandrel import ModelLoader

weights, pkg, img = sys.argv[1:4]
crop = Image.open(img).convert("RGB").crop((300, 200, 556, 456))
x = torch.from_numpy(np.asarray(crop)).permute(2, 0, 1)[None].float() / 255
ref = ModelLoader().load_from_file(weights).model.eval()
with torch.no_grad():
    t = time.time(); r = (ref.to("mps")(x.to("mps")).clamp(0, 1) * 255).cpu()[0].permute(1, 2, 0).numpy(); torch.mps.synchronize()
print(f"torch mps fp32 {time.time()-t:.2f}s (first call)")
for cu in ["ALL", "CPU_AND_GPU", "CPU_AND_NE"]:
    m = ct.models.MLModel(pkg, compute_units=getattr(ct.ComputeUnit, cu))
    m.predict({"image": crop})
    t = time.time(); out = m.predict({"image": crop})["upscaled"]; dt = time.time() - t
    o = np.asarray(out.convert("RGB")).astype(np.float32)
    mse = np.mean((o - r) ** 2); psnr = 10 * np.log10(255 ** 2 / max(mse, 1e-9))
    print(f"{cu:12s} {dt:.3f}s/tile  PSNR vs torch {psnr:.1f} dB")
    if cu == "ALL": out.save(sys.argv[4] if len(sys.argv) > 4 else "/dev/null", format="PNG")

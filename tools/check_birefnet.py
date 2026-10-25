"""Compare the Core ML BiRefNet matte with PyTorch (MPS, fp32) on one photo; time each compute unit."""
import sys, time, numpy as np, torch, coremltools as ct
from PIL import Image
from transformers import AutoModelForImageSegmentation
import convert_birefnet as cb

src, pkg, img, size = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
im = Image.open(img).convert("RGB").resize((size, size), Image.LANCZOS)
model = AutoModelForImageSegmentation.from_pretrained(src, trust_remote_code=True).eval().float()
sys.modules[type(model).__module__].deform_conv2d = cb.deform_conv2d
net = cb.Wrapper(model).eval().to("mps")
x = torch.from_numpy(np.array(im)).permute(2, 0, 1)[None].float().div(255).to("mps")
with torch.no_grad():
    t = time.time(); ref = net(x)[0, 0].cpu().numpy(); print(f"torch mps fp32 {time.time()-t:.2f}s")
for cu in ["CPU_AND_GPU", "ALL"]:
    t = time.time(); m = ct.models.MLModel(pkg, compute_units=getattr(ct.ComputeUnit, cu)); load = time.time() - t
    m.predict({"image": im})
    t = time.time(); out = m.predict({"image": im})["mask"]; dt = time.time() - t
    o = np.asarray(out).astype(np.float32)
    print(f"{cu:12s} load {load:.1f}s  {dt:.2f}s/image  mean|diff| {np.abs(o-ref).mean():.2f}/255  "
          f"IoU@0.5 {((o>127)&(ref>127)).sum()/max(((o>127)|(ref>127)).sum(),1):.4f}")
    out.save(sys.argv[5] if len(sys.argv) > 5 else "/dev/null", format="PNG")

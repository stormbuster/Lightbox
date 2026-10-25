#!/bin/zsh
# Downloads the official weights and converts them to Core ML packages in Lightbox/Models/.
#   BiRefNet_HR + BiRefNet_HR-matting (MIT, ZhengPeng7)  -> 2048 px background mattes
#   4xNomos2_hq_dat2 (Phhofm, CC-BY-4.0)                 -> faithful 4x photo upscaler (GPU)
#   4xBHI_dat2_real (Phhofm, CC-BY-4.0)                  -> 4x upscaler for compressed/noisy photos (GPU)
#   RealESRGAN_x4plus (xinntao, BSD-3)                    -> fast 4x upscaler (Neural Engine)
set -euo pipefail
cd "${0:A:h}"
[[ -x .venv/bin/python ]] || { uv venv -q -p 3.12 .venv && uv pip install -q -p .venv/bin/python \
    torch torchvision coremltools spandrel transformers timm einops kornia pillow huggingface_hub safetensors; }
mkdir -p cache/up cache/hf ../Lightbox/Models
dl() { [[ -s cache/up/$2 ]] || curl -fL --progress-bar -o cache/up/$2 "$1"; }
dl https://github.com/Phhofm/models/releases/download/4xNomos2_hq_dat2/4xNomos2_hq_dat2.pth 4xNomos2_hq_dat2.pth
dl https://github.com/Phhofm/models/releases/download/4xBHI_dat2_real/4xBHI_dat2_real.safetensors 4xBHI_dat2_real.safetensors
dl https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth RealESRGAN_x4plus.pth
for repo in BiRefNet_HR BiRefNet_HR-matting; do
    [[ -s cache/hf/$repo/model.safetensors ]] || HF_HOME=$PWD/cache/hf .venv/bin/hf download ZhengPeng7/$repo --local-dir cache/hf/$repo
done
M=../Lightbox/Models
[[ -d $M/BiRefNet_HR_2048.mlpackage ]] || .venv/bin/python convert_birefnet.py cache/hf/BiRefNet_HR $M/BiRefNet_HR_2048.mlpackage 2048
[[ -d $M/BiRefNet_HR_Matting_2048.mlpackage ]] || .venv/bin/python convert_birefnet.py cache/hf/BiRefNet_HR-matting $M/BiRefNet_HR_Matting_2048.mlpackage 2048
[[ -d $M/Nomos2_DAT2_x4.mlpackage ]] || .venv/bin/python convert_upscaler.py cache/up/4xNomos2_hq_dat2.pth $M/Nomos2_DAT2_x4.mlpackage 256
[[ -d $M/BHI_DAT2_Real_x4.mlpackage ]] || .venv/bin/python convert_upscaler.py cache/up/4xBHI_dat2_real.safetensors $M/BHI_DAT2_Real_x4.mlpackage 256
[[ -d $M/RealESRGAN_x4.mlpackage ]] || .venv/bin/python convert_upscaler.py cache/up/RealESRGAN_x4plus.pth $M/RealESRGAN_x4.mlpackage 256
ls -d $M/*.mlpackage

#!/bin/bash
# Fetches everything that is not in git: llama.cpp, the LFM3-VL weights and the Core ML detector.
# Needs: brew install xcodegen uv, and the `hf` CLI (pip install huggingface_hub).
set -euo pipefail
cd "$(dirname "$0")/.."
LLAMA_TAG=b12383

if [ ! -d Vendor/llama.xcframework ]; then
  mkdir -p Vendor/tmp
  curl -L -o Vendor/tmp/llama.zip "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_TAG/llama-$LLAMA_TAG-xcframework.zip"
  unzip -q Vendor/tmp/llama.zip -d Vendor/tmp
  mv Vendor/tmp/build-apple/llama.xcframework Vendor/
  rm -rf Vendor/tmp
fi

mkdir -p Models
# The app bundles Models/eyes-ft-v2-Q4_K_M.gguf (Witness-2B), a fine-tune of LFM3-VL-2B that is not on Hugging Face:
# copy it from ~/Documents/s26-eyes-lab/models/ (see the README). The stock weights below are still
# fetched, for comparison in eyes-cli and because the vision projector is shared.
if [ ! -f Models/LFM3-VL-2B-QAD-Q4_0.gguf ]; then
  hf download LiquidAI/LFM3-VL-2B-GGUF LFM3-VL-2B-QAD-Q4_0.gguf --local-dir Models
  hf download LiquidAI/LFM3-VL-2B-GGUF mmproj-LFM3-VL-2B-Q8_0.gguf --local-dir Models
fi

# Speech to text: Parakeet Unified 0.6B, the streaming export the app uses (ParakeetTranscriber).
if [ ! -d Models/parakeet-unified-en-0.6b ]; then
  hf download FluidInference/parakeet-unified-en-0.6b-coreml --local-dir Models/parakeet-unified-en-0.6b \
    --include "config.json" "metadata.json" "vocab.json" "parakeet_unified_decoder.mlmodelc/*" \
    "parakeet_unified_joint_decision_single_step.mlmodelc/*" "parakeet_unified_encoder_streaming_70_7_7_int8.mlmodelc/*"
fi

if [ ! -d Models/yoloe26m.mlpackage ]; then
  [ -d tools/.venv ] || uv venv --python 3.12 tools/.venv
  uv pip install -q --python tools/.venv/bin/python ultralytics coremltools "numpy<2.3" pillow
  mkdir -p tools/work
  (cd tools/work && ../.venv/bin/python ../export_yoloe.py)
fi

xcodegen generate
echo "Done. Open Eyes.xcodeproj, or see README.md."

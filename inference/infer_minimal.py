#!/usr/bin/env python3
"""Minimal NPU inference test - no torch dependency."""
import os, sys, glob, time
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../.."))
from utils.label.imagenet_classes import id2class
from utils.NOE_Engine import EngineInfer

def preprocess(image_path, size=224):
    """ImageNet preprocessing: resize, center-crop, normalize."""
    img = Image.open(image_path).convert("RGB")
    short_side = size + 32
    w, h = img.size
    if w < h:
        new_w, new_h = short_side, int(h * short_side / w)
    else:
        new_w, new_h = int(w * short_side / h), short_side
    img = img.resize((new_w, new_h), Image.BILINEAR)
    left = (new_w - size) // 2
    top  = (new_h - size) // 2
    img = img.crop((left, top, left + size, top + size))
    arr = np.asarray(img).astype(np.float32) / 255.0
    mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)
    std  = np.array([0.229, 0.224, 0.225], dtype=np.float32)
    arr = (arr - mean) / std
    arr = np.transpose(arr, (2, 0, 1))[None]
    return np.ascontiguousarray(arr)

def main():
    model_path = "mobilenet_v2.cix"
    images = sorted(glob.glob("test_data/*.JPEG"))
    print(f"Loading model: {model_path}")
    model = EngineInfer(model_path)
    print(f"Model loaded. Running inference on {len(images)} images...")
    print()
    times = []
    for i, ip in enumerate(images, 1):
        x = preprocess(ip)
        t0 = time.perf_counter_ns()
        out = model.forward(x)[0]
        elapsed_ms = (time.perf_counter_ns() - t0) / 1e6
        times.append(elapsed_ms)
        pred = int(np.argmax(out))
        # top-5
        top5 = np.argsort(out.flatten())[-5:][::-1]
        print(f"[{i}/{len(images)}] {os.path.basename(ip)}")
        print(f"  inference: {elapsed_ms:.2f} ms")
        print(f"  top-1: id={pred} -> {id2class[pred]}")
        print(f"  top-5: " + ", ".join(f"{int(t)}={id2class[int(t)]}" for t in top5))
        print()
    if len(times) > 1:
        print(f"=== {len(times)} inferences: avg {sum(times)/len(times):.2f} ms, min {min(times):.2f} ms, max {max(times):.2f} ms ===")
    model.clean()
    print("OK")

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Export LettuceDetect model to ONNX format for use with Arcana's grounding pipeline.

Usage:
    python scripts/export_lettuce_onnx.py [--output-dir priv/models/lettucedect]

Requirements:
    pip install transformers torch onnx onnxruntime

The exported model.onnx file should be referenced in your Elixir config:

    config :arcana, Arcana.Grounding.Serving,
      model_path: "priv/models/lettucedect/model.onnx"
"""

import argparse
import os

import torch
from transformers import AutoModelForTokenClassification, AutoTokenizer

MODEL_ID = "KRLabsOrg/lettucedect-base-modernbert-en-v1"


def export_onnx(output_dir: str):
    os.makedirs(output_dir, exist_ok=True)

    print(f"Loading model: {MODEL_ID}")
    model = AutoModelForTokenClassification.from_pretrained(MODEL_ID)
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    model.eval()

    # Create dummy inputs as a pair (context, answer)
    dummy = tokenizer(
        "This is context. Question: What is this?",
        "This is the answer.",
        return_tensors="pt",
        max_length=512,
        truncation=True,
    )

    output_path = os.path.join(output_dir, "model.onnx")

    print(f"Exporting to ONNX: {output_path}")
    torch.onnx.export(
        model,
        (dummy["input_ids"], dummy["attention_mask"]),
        output_path,
        input_names=["input_ids", "attention_mask"],
        output_names=["logits"],
        dynamic_axes={
            "input_ids": {0: "batch", 1: "sequence"},
            "attention_mask": {0: "batch", 1: "sequence"},
            "logits": {0: "batch", 1: "sequence"},
        },
        opset_version=14,
    )

    # Save tokenizer alongside the model for reference
    tokenizer.save_pretrained(output_dir)

    print(f"Done. Model exported to {output_path}")
    print(f"Tokenizer saved to {output_dir}")
    print()
    print("Add to your Elixir config:")
    print()
    print(f'    config :arcana, Arcana.Grounding.Serving,')
    print(f'      model_path: "{output_path}"')


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Export LettuceDetect to ONNX")
    parser.add_argument(
        "--output-dir",
        default="priv/models/lettucedect",
        help="Directory to save the ONNX model (default: priv/models/lettucedect)",
    )
    args = parser.parse_args()
    export_onnx(args.output_dir)

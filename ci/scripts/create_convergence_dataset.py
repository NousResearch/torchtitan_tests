#!/usr/bin/env python3
"""
Generate a small deterministic nanoset dataset for convergence testing.

Creates .ds, .ds.index, and .ds.metadata files with random token IDs
from a fixed seed, ensuring identical data across all CI runs.

Format matches datatrove's DatatroveFolderDataset:
  .ds       — uint32 token IDs (sequential)
  .ds.index — uint64 cumulative token counts per document
  .ds.metadata — "tokenizer_name|token_size\ntotal_tokens\nsize_str"
"""

import argparse
import os
import struct
import sys


def create_dataset(output_dir, seed=12345, vocab_size=151936, num_tokens=40_000_000,
                   doc_length=8192, token_size=4):
    """Generate a synthetic nanoset dataset.

    Args:
        output_dir: Directory to write files into
        seed: Fixed random seed for reproducibility
        vocab_size: Max token ID (exclusive)
        num_tokens: Total tokens to generate (~100 steps * 8 gpus * 8 batch * 4096 seq + margin)
        doc_length: Tokens per document
        token_size: Bytes per token (4 for uint32)
    """
    os.makedirs(output_dir, exist_ok=True)

    ds_path = os.path.join(output_dir, "convergence_data.ds")
    idx_path = os.path.join(output_dir, "convergence_data.ds.index")
    meta_path = os.path.join(output_dir, "convergence_data.ds.metadata")

    # Check if already exists
    if os.path.exists(ds_path) and os.path.exists(idx_path):
        existing_size = os.path.getsize(ds_path)
        expected_size = num_tokens * token_size
        if abs(existing_size - expected_size) < expected_size * 0.01:
            print(f"Dataset already exists at {output_dir} ({existing_size} bytes)")
            return

    print(f"Generating convergence dataset: {num_tokens:,} tokens, seed={seed}")
    print(f"  vocab_size={vocab_size}, doc_length={doc_length}, token_size={token_size}")

    # Use a simple LCG (linear congruential generator) for speed and portability.
    # This avoids numpy dependency and produces identical output everywhere.
    # LCG parameters (Numerical Recipes)
    a = 1664525
    b = 1013904223
    m = 2**32
    state = seed

    # Write .ds file (token data) and .ds.index (document boundaries)
    num_docs = (num_tokens + doc_length - 1) // doc_length
    tokens_written = 0

    with open(ds_path, "wb") as ds_f, open(idx_path, "wb") as idx_f:
        for doc_i in range(num_docs):
            remaining = num_tokens - tokens_written
            this_doc_len = min(doc_length, remaining)
            if this_doc_len <= 0:
                break

            # Generate tokens for this document
            buf = bytearray(this_doc_len * token_size)
            for j in range(this_doc_len):
                state = (a * state + b) % m
                token_id = state % vocab_size
                struct.pack_into("<I", buf, j * token_size, token_id)

            ds_f.write(buf)
            tokens_written += this_doc_len

            # Index: cumulative token count
            idx_f.write(struct.pack("<Q", tokens_written))

            if (doc_i + 1) % 1000 == 0:
                pct = tokens_written / num_tokens * 100
                print(f"  {pct:.0f}% ({tokens_written:,} tokens, {doc_i+1} docs)")

    # Write metadata
    size_gb = tokens_written * token_size / 1e9
    with open(meta_path, "w") as f:
        f.write(f"synthetic-convergence|{token_size}\n")
        f.write(f"{tokens_written}\n")
        f.write(f"{size_gb:.2f} GB\n")

    file_size = os.path.getsize(ds_path)
    print(f"Done: {tokens_written:,} tokens in {num_docs} docs")
    print(f"  {ds_path}: {file_size:,} bytes ({file_size/1e6:.1f} MB)")
    print(f"  {idx_path}: {os.path.getsize(idx_path):,} bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate convergence test dataset")
    parser.add_argument("output_dir", help="Output directory for nanoset files")
    parser.add_argument("--seed", type=int, default=12345, help="Random seed")
    parser.add_argument("--num-tokens", type=int, default=40_000_000,
                        help="Total tokens (default: 40M, enough for 100 steps with 8xGPU)")
    parser.add_argument("--doc-length", type=int, default=8192, help="Tokens per document")
    parser.add_argument("--vocab-size", type=int, default=151936, help="Vocabulary size")
    args = parser.parse_args()

    create_dataset(args.output_dir, seed=args.seed, vocab_size=args.vocab_size,
                   num_tokens=args.num_tokens, doc_length=args.doc_length)

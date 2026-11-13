"""Offline caption worker. Single-image app calls and bounded CLI batches."""
import argparse
import contextlib
import json
import os
import sys
import time
import hashlib
import importlib.metadata
from pathlib import Path

os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", TOKENIZERS_PARALLELISM="false")
PROMPT = "Describe the visible objects in this image in one sentence. Do not guess a location or plant species."
BRIEF_PROMPT = "Name the main visible objects in at most 12 words. Do not guess a location or plant species."


def validate(result):
    caption = result.text.strip()
    words = caption.casefold().split()
    grams = [tuple(words[i:i + 4]) for i in range(max(0, len(words) - 3))]
    if result.finish_reason != "stop" or not caption or len(caption) > 2000:
        raise ValueError("Incomplete caption")
    if grams and 1 - len(set(grams)) / len(grams) > 0.2:
        raise ValueError("Repeated phrases")
    return caption


class Captioner:
    def __init__(self, path):
        import mlx.core as mx
        from mlx_vlm import generate, load
        from mlx_vlm.prompt_utils import apply_chat_template
        from mlx_vlm.utils import load_config
        start = time.monotonic()
        self.mx, self.generate = mx, generate
        self.model, self.processor = load(path, use_fast=False, trust_remote_code=False)
        config = load_config(path)
        self.prompts = [apply_chat_template(self.processor, config, p, num_images=1, enable_thinking=False)
                        for p in [PROMPT, BRIEF_PROMPT]]
        self.load_seconds = time.monotonic() - start
        self.config_sha256 = hashlib.sha256((Path(path) / "config.json").read_bytes()).hexdigest()
        self.versions = {name: importlib.metadata.version(name) for name in ["mlx", "mlx-vlm"]}

    def caption(self, image, retry_brief=False):
        start = time.monotonic()
        last_error = None
        for attempt in range(2 if retry_brief else 1):
            self.mx.random.seed(42)
            self.mx.reset_peak_memory()
            result = self.generate(self.model, self.processor, self.prompts[attempt], image=[image],
                max_tokens=64 if attempt else 128, temperature=0.1, top_k=50, top_p=1.0,
                repetition_penalty=1.15 if attempt else 1.1, verbose=False)
            try:
                caption = validate(result)
                return dict(caption=caption, seconds=time.monotonic()-start,
                    peak_memory_gb=result.peak_memory, generation_tokens=result.generation_tokens,
                    finish_reason=result.finish_reason, prompt_mode="brief_retry" if attempt else "standard",
                    prompt_version="visible-objects-en-v1", runtime_versions=self.versions,
                    model_config_sha256=self.config_sha256)
            except ValueError as error:
                last_error = error
            finally:
                self.mx.clear_cache()
        raise last_error


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--image")
    group.add_argument("--batch-manifest")
    args = parser.parse_args()
    with contextlib.redirect_stdout(sys.stderr):
        captioner = Captioner(args.model)
    if args.image:
        with contextlib.redirect_stdout(sys.stderr):
            output = captioner.caption(args.image)
        output["seconds"] += captioner.load_seconds
        output["load_seconds"] = captioner.load_seconds
        print(json.dumps(output, ensure_ascii=False), flush=True)
    else:
        with open(args.batch_manifest, encoding="utf-8") as handle:
            requests = json.load(handle)
        if not 1 <= len(requests) <= 32 or len({x['id'] for x in requests}) != len(requests):
            raise ValueError("Invalid batch")
        for index, request in enumerate(requests):
            try:
                with contextlib.redirect_stdout(sys.stderr):
                    output = captioner.caption(request['image'], retry_brief=True)
                output['load_seconds'] = captioner.load_seconds if index == 0 else 0
                output['seconds'] += output['load_seconds']
                response = dict(id=request['id'], result=output)
            except Exception as error:
                response = dict(id=request['id'], error=type(error).__name__)
            print(json.dumps(response, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"error": type(error).__name__}), flush=True)
        sys.exit(1)

"""A minimal text-in, text-out wrapper over the model providers.

Backends, selected by RANDOM_LLM_BACKEND (default: the first one with a key):

  anthropic   the official SDK, key in ANTHROPIC_API_KEY,
              model in RANDOM_LLM_MODEL (default claude-opus-5-5)
  openai      the official SDK, key in OPENAI_API_KEY,
              model in RANDOM_LLM_MODEL (default gpt-5)
  claude-cli  the local `claude -p` command, for testing without an API key

Current Claude models reject sampling parameters (temperature, top_p), so the
entropy of the generated queries comes from the prompts (see
generate-queries.py). RANDOM_LLM_TEMPERATURE is sent only to the openai
backend and only when set, for the models that accept it.
"""

import os
import shutil
import subprocess


def backend():
    b = os.environ.get("RANDOM_LLM_BACKEND", "")
    if b:
        return b
    if os.environ.get("ANTHROPIC_API_KEY"):
        return "anthropic"
    if os.environ.get("OPENAI_API_KEY"):
        return "openai"
    if shutil.which("claude"):
        return "claude-cli"
    raise RuntimeError("No LLM backend: set ANTHROPIC_API_KEY or OPENAI_API_KEY")


def describe():
    b = backend()
    return f"{b}:{model(b)}"


def model(b):
    m = os.environ.get("RANDOM_LLM_MODEL", "")
    if m:
        return m
    return {"anthropic": "claude-opus-5-5", "openai": "gpt-5", "claude-cli": "default"}[b]


def complete(system, prompt, max_tokens=64000):
    b = backend()
    if b == "anthropic":
        import anthropic
        client = anthropic.Anthropic(max_retries=5)
        # Streaming, because the outputs are long.
        with client.messages.stream(
            model=model(b),
            max_tokens=max_tokens,
            system=system,
            output_config={"effort": os.environ.get("RANDOM_LLM_EFFORT", "high")},
            messages=[{"role": "user", "content": prompt}],
        ) as stream:
            message = stream.get_final_message()
        if message.stop_reason == "refusal":
            raise RuntimeError("the model declined the request")
        if message.stop_reason == "max_tokens":
            raise RuntimeError("the response was cut at max_tokens")
        return "".join(block.text for block in message.content if block.type == "text")
    if b == "openai":
        import openai
        client = openai.OpenAI(max_retries=5)
        kwargs = {}
        if os.environ.get("RANDOM_LLM_TEMPERATURE"):
            kwargs["temperature"] = float(os.environ["RANDOM_LLM_TEMPERATURE"])
        response = client.responses.create(
            model=model(b),
            instructions=system,
            input=prompt,
            max_output_tokens=max_tokens,
            **kwargs,
        )
        if response.status != "completed":
            raise RuntimeError(f"the response is {response.status}")
        return response.output_text
    if b == "claude-cli":
        args = ["claude", "-p", "--output-format", "text", "--append-system-prompt", system,
                "--tools", "", "--no-session-persistence"]
        if os.environ.get("RANDOM_LLM_MODEL"):
            args += ["--model", os.environ["RANDOM_LLM_MODEL"]]
        result = subprocess.run(args, input=prompt, capture_output=True, text=True, timeout=3600)
        if result.returncode != 0:
            raise RuntimeError(f"claude -p failed: {result.stderr[-2000:]}")
        return result.stdout
    raise RuntimeError(f"Unknown backend {b}")

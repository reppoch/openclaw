#!/usr/bin/env bash
# Patch upstream Dockerfile so pnpm build:docker (write-cli-startup-metadata) does not
# hang in CI/QEMU: disable P2P/bundled plugins during metadata generation.
set -euo pipefail

DOCKERFILE="${1:-Dockerfile}"

if [[ ! -f "$DOCKERFILE" ]]; then
  echo "ERROR: Dockerfile not found: $DOCKERFILE" >&2
  exit 1
fi

if grep -q 'OPENCLAW_DISABLE_P2P=1' "$DOCKERFILE" && grep -q 'pnpm build:docker' "$DOCKERFILE"; then
  echo "Dockerfile already patched for CI build:docker ($DOCKERFILE)"
  exit 0
fi

python3 - "$DOCKERFILE" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

env_block = """ENV CI=true \\
    OPENCLAW_DISABLE_P2P=1 \\
    OPENCLAW_DISABLE_BUNDLED_PLUGINS=1"""

# Release tags / older main: one RUN line ending with pnpm build:docker
single_line_repl = env_block + """
RUN NODE_OPTIONS=--max-old-space-size=8192 \\
    CI=true \\
    OPENCLAW_DISABLE_P2P=1 \\
    OPENCLAW_DISABLE_BUNDLED_PLUGINS=1 \\
    pnpm_config_verify_deps_before_run=false \\
    pnpm build:docker"""

# Older main: multi-line RUN (qa-lab guard) ending with pnpm build:docker
multiline_repl = env_block + """
RUN if printf '%s\\n' "$OPENCLAW_EXTENSIONS" | tr ',' ' ' | tr ' ' '\\n' | grep -qx 'qa-lab'; then \\
      export OPENCLAW_BUILD_PRIVATE_QA=1 OPENCLAW_ENABLE_PRIVATE_QA_CLI=1; \\
    fi && \\
    CI=true OPENCLAW_DISABLE_P2P=1 OPENCLAW_DISABLE_BUNDLED_PLUGINS=1 NODE_OPTIONS=--max-old-space-size=8192 pnpm_config_verify_deps_before_run=false pnpm build:docker"""

patterns = [
    (
        re.compile(r"^RUN .*pnpm build:docker\s*$", re.MULTILINE),
        single_line_repl,
        "single-line RUN ... pnpm build:docker",
    ),
    (
        re.compile(r"^RUN if printf.*?pnpm build:docker\s*$", re.MULTILINE | re.DOTALL),
        multiline_repl,
        "multi-line RUN (qa-lab) ... pnpm build:docker",
    ),
]

new_text = text
matched = None
for pattern, replacement, label in patterns:
    # Callable replacement: re.sub interprets \n and \\ in string replacements.
    candidate, count = pattern.subn(lambda m, repl=replacement: repl, new_text, count=1)
    if count == 1:
        new_text = candidate
        matched = label
        break

if matched is None and "RUN set -eu;" in text and "pnpm build:docker" in text:
    ci_prefix = "CI=true OPENCLAW_DISABLE_P2P=1 OPENCLAW_DISABLE_BUNDLED_PLUGINS=1 "
    lines = text.splitlines(keepends=True)
    out = []
    env_inserted = False
    build_line_patched = False

    for line in lines:
        if (
            not env_inserted
            and line.startswith("RUN set -eu;")
        ):
            out.append(env_block + "\n")
            env_inserted = True

        if (
            "pnpm build:docker" in line
            and "OPENCLAW_DISABLE_P2P=1" not in line
        ):
            m = re.match(r"^(\s+)(.+)$", line.rstrip("\n"))
            if m:
                line = f"{m.group(1)}{ci_prefix}{m.group(2)}\n"
                build_line_patched = True

        out.append(line)

    if env_inserted and build_line_patched:
        new_text = "".join(out)
        matched = "RUN set -eu (plugin selection) ... pnpm build:docker"

if matched is None:
    sys.stderr.write(
        f"ERROR: no supported pnpm build:docker RUN block found in {path}\n"
        f"  (expected single-line RUN, qa-lab multi-line RUN, or RUN set -eu plugin block)\n"
    )
    sys.exit(1)

path.write_text(new_text, encoding="utf-8")
print(f"Patched {path} for CI build:docker ({matched})")
PY

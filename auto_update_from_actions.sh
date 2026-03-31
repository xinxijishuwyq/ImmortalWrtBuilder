#!/bin/sh
# 自动检查 GitHub Actions 新构建并执行 OpenWrt sysupgrade
# 依赖：curl、jq、unzip、sysupgrade
# 用法：
#   GITHUB_OWNER=xxx GITHUB_REPO=yyy WORKFLOW_FILE=build.yml \
#   ARTIFACT_NAME=openwrt-firmware TARGET_GLOB='*sysupgrade*.bin' \
#   GITHUB_TOKEN=ghp_xxx ./auto_update_from_actions.sh

set -eu

: "${GITHUB_OWNER:?请设置 GITHUB_OWNER}"
: "${GITHUB_REPO:?请设置 GITHUB_REPO}"
: "${WORKFLOW_FILE:?请设置 WORKFLOW_FILE (例如 build.yml)}"
: "${ARTIFACT_NAME:?请设置 ARTIFACT_NAME (Actions 产物名)}"

TARGET_GLOB="${TARGET_GLOB:-*sysupgrade*.bin}"
STATE_FILE="${STATE_FILE:-/etc/github_actions_build_id}"
WORKDIR="${WORKDIR:-/tmp/gh-actions-update}"

API_BASE="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}"
AUTH_HEADER=""
if [ -n "${GITHUB_TOKEN:-}" ]; then
  AUTH_HEADER="Authorization: Bearer ${GITHUB_TOKEN}"
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少命令: $1" >&2
    exit 1
  fi
}

api_get() {
  url="$1"
  if [ -n "$AUTH_HEADER" ]; then
    curl -fsSL -H "$AUTH_HEADER" -H "Accept: application/vnd.github+json" "$url"
  else
    curl -fsSL -H "Accept: application/vnd.github+json" "$url"
  fi
}

need_cmd curl
need_cmd jq
need_cmd unzip
need_cmd sysupgrade

mkdir -p "$WORKDIR"

# 1) 查询 workflow 最新成功 run
runs_json="$(api_get "${API_BASE}/actions/workflows/${WORKFLOW_FILE}/runs?status=success&per_page=1")"
latest_run_id="$(echo "$runs_json" | jq -r '.workflow_runs[0].id // empty')"
head_sha="$(echo "$runs_json" | jq -r '.workflow_runs[0].head_sha // empty')"

if [ -z "$latest_run_id" ]; then
  echo "未找到成功构建，退出"
  exit 0
fi

current_id=""
if [ -f "$STATE_FILE" ]; then
  current_id="$(cat "$STATE_FILE" 2>/dev/null || true)"
fi

if [ "$latest_run_id" = "$current_id" ]; then
  echo "当前已是最新构建 (run_id=$latest_run_id, sha=$head_sha)"
  exit 0
fi

# 2) 查询该 run 的 artifacts
arts_json="$(api_get "${API_BASE}/actions/runs/${latest_run_id}/artifacts")"
artifact_id="$(echo "$arts_json" | jq -r --arg n "$ARTIFACT_NAME" '.artifacts[] | select(.name==$n and .expired==false) | .id' | head -n1)"

if [ -z "$artifact_id" ]; then
  echo "没有找到名为 '$ARTIFACT_NAME' 的可用 artifact，退出" >&2
  exit 1
fi

zip_file="${WORKDIR}/artifact-${latest_run_id}.zip"
extract_dir="${WORKDIR}/artifact-${latest_run_id}"
rm -rf "$extract_dir"
mkdir -p "$extract_dir"

# 3) 下载 artifact 压缩包
download_url="${API_BASE}/actions/artifacts/${artifact_id}/zip"
if [ -n "$AUTH_HEADER" ]; then
  curl -fL -H "$AUTH_HEADER" -H "Accept: application/vnd.github+json" "$download_url" -o "$zip_file"
else
  curl -fL -H "Accept: application/vnd.github+json" "$download_url" -o "$zip_file"
fi

unzip -o "$zip_file" -d "$extract_dir" >/dev/null

firmware_file="$(find "$extract_dir" -type f -name "$TARGET_GLOB" | head -n1 || true)"
if [ -z "$firmware_file" ]; then
  echo "artifact 已下载，但未找到匹配固件: $TARGET_GLOB" >&2
  exit 1
fi

echo "发现新构建，准备升级:"
echo "  run_id: $latest_run_id"
echo "  head_sha: $head_sha"
echo "  firmware: $firmware_file"

# 4) 标记最新构建并执行升级（保留配置）
printf '%s' "$latest_run_id" > "$STATE_FILE"
# 如需不保留配置，请改为: sysupgrade -n "$firmware_file"
sysupgrade "$firmware_file"

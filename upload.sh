#!/bin/sh
# ============================================================
#  一键部署到 fork 仓库（可选脚本）
#  用法：
#    1. 修改下面的 REPO_URL 为你自己的 fork 地址
#    2. 在本目录执行：./upload.sh
#  脚本会把 configs/ scripts/ .github/ files/ README.md 同步到你 fork 仓库根目录
# ============================================================
set -e

REPO_URL="${REPO_URL:-https://github.com/Wu140360/openwrt-ci-roc.git}"
BRANCH="${BRANCH:-main}"

cd "$(dirname "$0")"

# 用 rsync 精确同步所需文件到临时目录，再推送到 fork
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

rsync -av --exclude='.git' \
      --include='.github/***' \
      --include='configs/***' \
      --include='scripts/***' \
      --include='files/***' \
      --include='README.md' \
      --include='check.sh' \
      --include='upload.sh' \
      --exclude='*' \
      ./ "$TMP/"

cd "$TMP"
git init -q
git checkout -q -b "$BRANCH"
git add .
git commit -q -m "feat: add ZN-M2 dedicated build config (no-wifi, no-usb, full NSS)"
git remote add origin "$REPO_URL"
echo "==> 已准备好提交，执行以下命令推送到你的 fork："
echo "    cd $TMP && git push -u origin $BRANCH"

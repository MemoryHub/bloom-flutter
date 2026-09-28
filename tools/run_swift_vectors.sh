#!/usr/bin/env bash
# 用共享测试向量验证 iOS 侧的查表规则。
#
# BloomSharedState.swift 刻意只依赖 Foundation，因此可以脱离模拟器，直接用
# swiftc 在 macOS 上编译运行。规则改坏会立刻红，而不是等装到手机上才发现。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O \
  "$ROOT/ios/BloomWidgets/BloomSharedState.swift" \
  "$ROOT/tools/swift_vectors/main.swift" \
  -o "$OUT/runner"

"$OUT/runner" "$ROOT/test/vectors/carousel_vectors.json"

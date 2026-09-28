#!/usr/bin/env bash
# Bloom 轮播重写 · 三端一致性验证
#
# 一条命令跑完所有「三端必须一致」的规则与回归测试。
#
# 为什么需要这个脚本：共享向量本身是**同一份文件**
# （test/vectors/carousel_vectors.json），但三个消费方各有各的运行方式——
# Dart 走 flutter test、安卓走 Kotlin JVM 单测、iOS 走 swiftc 独立编译。
# 分散着记命令，结果一定是改完一处只跑一端，另一端的规则悄悄腐烂。
#
# 用法：
#   tools/verify_all.sh
#   BLOOM_SERVER_DIR=/path/to/frame-service tools/verify_all.sh
#
# 退出码：全部通过为 0，任一步失败为 1。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="${BLOOM_SERVER_DIR:-/Users/zhangbo/immich-frame-web-customization/frame-service}"
export PATH="/Users/zhangbo/development/flutter/bin:$PATH"

RESULTS=()
FAILED=0
SKIPPED=()

# ---------------------------------------------------------------------------
# 各端验证步骤。每步都是独立的 shell 函数，失败不中断后续步骤——一次跑完
# 拿到完整清单，比修一个跑一次快得多。
# ---------------------------------------------------------------------------

step_dart() {
  echo "共享向量的 Dart 消费方，以及状态契约、留存规则、引擎流程的回归。"
  # compact reporter 的进度是 \r 覆盖式输出，抓 tail 会得到一坨巨大的单行。
  # failures-only 只在失败时展开，成功时只留一行结论。
  ( cd "$ROOT" && flutter test --reporter failures-only 2>&1 | tail -5 )
}

step_android() {
  echo "共享向量的 Kotlin 消费方（JVM 单测，不需要模拟器或真机）。"
  ( cd "$ROOT/android" && ./gradlew :app:testDebugUnitTest --console=plain 2>&1 | tail -12 )
  # **Gradle 说 SUCCESSFUL 不等于跑了用例。** 过滤条件写错、源集漏配、任务被
  # 判成 UP-TO-DATE，都会让任务零用例通过——这条脚本自己就踩过一次。所以这里
  # 不看退出码，直接数结果 XML 里的真实用例数。
  # 注意 buildDir 被 Flutter 重定向到了根的 build/app，不是 android/app/build。
  local results="$ROOT/build/app/test-results/testDebugUnitTest"
  local total
  total=$(awk -F'tests="' '/<testsuite /{split($2,a,"\""); s+=a[1]} END{print s+0}' \
    "$results"/TEST-*.xml 2>/dev/null)
  if [ "${total:-0}" -lt 10 ]; then
    echo "✗ 安卓单测只跑了 ${total:-0} 个用例（预期 >=10）：疑似被过滤成空跑"
    return 1
  fi
  echo "安卓单测真实用例数：$total"
}

step_swift() {
  echo "共享向量的 Swift 消费方，外加共享状态键名映射的契约检查。"
  "$ROOT/tools/run_swift_vectors.sh"
}

step_server() {
  local ignores=()
  # test_content_version.py 依赖 pillow_heif，本地环境常常没装。这是既有的
  # 环境缺失，不是代码问题——显式探测后跳过，并在结论里标明，避免它被误读
  # 成"服务端测试全过了"。
  if ! python3 -c 'import pillow_heif' >/dev/null 2>&1; then
    ignores+=(--ignore=tests/test_content_version.py)
    echo "（未安装 pillow_heif，跳过 tests/test_content_version.py）"
  fi
  ( cd "$SERVER" && python3 -m pytest tests/ -q "${ignores[@]}" 2>&1 | tail -6 )
}

# ---------------------------------------------------------------------------

run_step() {
  local name="$1" fn="$2"
  echo
  echo "═══════════════════════════════════════════════"
  echo "▶ $name"
  echo "═══════════════════════════════════════════════"
  if "$fn"; then
    RESULTS+=("通过  $name")
  else
    RESULTS+=("失败  $name")
    FAILED=1
  fi
}

echo "Bloom 轮播重写 · 三端一致性验证"
echo "仓库: $ROOT"
echo "服务端: $SERVER"

# ---------------------------------------------------------------------------
# 先确认关键测试文件都还在。
#
# 这类脚本最危险的失败模式不是红，而是**假绿**：某个测试文件被改名或误删后，
# 测试任务照样「成功」，只是跑了 0 个用例。跑之前先点一遍名，成本近乎为零。
# ---------------------------------------------------------------------------
REQUIRED_FILES=(
  "test/vectors/carousel_vectors.json"
  "test/carousel/carousel_rules_test.dart"
  "test/carousel/state_store_test.dart"
  "test/carousel/carousel_engine_test.dart"
  "test/carousel/plan_client_test.dart"
  "test/carousel/next_slot_read_test.dart"
  "test/carousel/photo_gc_test.dart"
  "lib/core/carousel/photo_gc.dart"
  "lib/ui/bloom_keep_alive_card.dart"
  "packages/bloom_widget_bridge/android/src/main/kotlin/com/bloom/widget_bridge/BloomKeepAlive.kt"
  "android/app/src/test/kotlin/com/bloom/bloom/KeepAliveApplicabilityTest.kt"
  "android/app/src/test/kotlin/com/bloom/bloom/CarouselVectorsTest.kt"
  "ios/BloomWidgets/BloomSharedState.swift"
  "tools/swift_vectors/main.swift"
)

MISSING=()
for rel in "${REQUIRED_FILES[@]}"; do
  [ -f "$ROOT/$rel" ] || MISSING+=("$rel")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo
  echo "✗ 关键测试文件缺失，拒绝继续——缺失时后面几步会「成功」但实际没测任何东西："
  for rel in "${MISSING[@]}"; do echo "    $rel"; done
  exit 1
fi
echo "关键测试文件齐全（${#REQUIRED_FILES[@]} 个）"

run_step "Dart（FAPP 内核与规则）" step_dart
run_step "安卓原生（Kotlin 单测）" step_android
run_step "iOS 原生（Swift 独立编译）" step_swift

if [ -d "$SERVER" ]; then
  run_step "服务端（Python）" step_server
else
  SKIPPED+=("服务端：目录不存在 $SERVER（用 BLOOM_SERVER_DIR 指定）")
fi

# ---------------------------------------------------------------------------

echo
echo "═══════════════════════════════════════════════"
echo "结论"
echo "═══════════════════════════════════════════════"
for line in "${RESULTS[@]}"; do
  echo "  $line"
done
for line in "${SKIPPED[@]:-}"; do
  [ -n "$line" ] && echo "  跳过  $line"
done

echo
if [ "$FAILED" -ne 0 ]; then
  echo "✗ 有步骤失败——三端一致性尚未成立，不要构建安装包。"
  exit 1
fi
echo "✓ 三端共享规则一致，可以进入构建与真机核对。"
echo "  真机步骤见 _bloom_app_plan/Bloom轮播重写真机核对清单.docx"

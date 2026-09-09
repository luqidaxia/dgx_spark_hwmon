#!/usr/bin/env bash
# ============================================================
# spark_hwmon (spbm) 卸载脚本
# 用法：sudo ./uninstall.sh
# ============================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "请以 root 运行：sudo $0"; exit 1; }

echo "==> 卸载模块"
modprobe -r spbm 2>/dev/null || true

echo "==> 移除 DKMS 记录"
FOUND=0
for v in $(dkms status spbm 2>/dev/null | sed -E 's#^spbm/([^,:]+).*#\1#'); do
    FOUND=1
    dkms remove "spbm/$v" --all || true
done
[ "$FOUND" -eq 1 ] || echo "    未发现已注册的 spbm DKMS 模块"

echo
echo "✅ 已卸载 spbm"
echo "   如需恢复默认功耗策略，可重启节点。"

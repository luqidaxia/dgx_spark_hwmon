#!/usr/bin/env bash
# ============================================================
# spark_hwmon (spbm) 一键安装脚本 —— DKMS 方式
# 适用：NVIDIA DGX Spark (GB10 SoC)，内核 6.11+ ARM64
# 用法：sudo ./install.sh
# ============================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "请以 root 运行：sudo $0"; exit 1; }

KREL="$(uname -r)"
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "==> [1/5] 安装依赖：dkms / git / linux-headers-$KREL"
apt-get install -y dkms git "linux-headers-$KREL" || {
    echo "    依赖安装失败，尝试 apt-get update 后重试"
    apt-get update
    apt-get install -y dkms git "linux-headers-$KREL"
}

cd "$SRC"

echo "==> [2/5] 清理可能残留的 DKMS 状态"
# 仅 "added" 但源码目录丢失时，直接 build 会失败；先 remove 再重新 add
for v in $(dkms status spbm 2>/dev/null | sed -E 's#^spbm/([^,:]+).*#\1#'); do
    dkms remove "spbm/$v" --all >/dev/null 2>&1 || true
done

echo "==> [3/5] dkms add"
dkms add .

# 注意：dkms status 输出形如 "spbm/0.3.0: added" 或
# "spbm/0.3.0, 6.17.0-1022-nvidia, aarch64: installed"，
# 版本号必须排除 ':' 与 ','，否则会把状态串当成版本传给 dkms。
VER=$(dkms status spbm 2>/dev/null | head -1 | sed -E 's#^spbm/([^,:]+).*#\1#')
[ -n "$VER" ] || { echo "无法解析 dkms 版本号"; exit 1; }
echo "    版本：$VER"

echo "==> [4/5] dkms build + install"
dkms build "spbm/$VER"
dkms install "spbm/$VER"

echo "==> [5/5] 重新加载模块"
# 若旧版本仍在内存中，必须先卸载，否则 modprobe 不会替换已加载的模块
modprobe -r spbm 2>/dev/null || true
modprobe spbm || true
sleep 1

DEV=""
for d in /sys/class/hwmon/hwmon*; do
    [ -f "$d/name" ] || continue
    if [ "$(cat "$d/name" 2>/dev/null)" = "spbm" ]; then DEV="$d"; break; fi
done

if [ -n "$DEV" ]; then
    W="$(awk '{printf "%.2f", $1/1e6}' "$DEV/power1_input" 2>/dev/null || echo '-')"
    echo
    echo "✅ 安装成功：spbm -> $DEV（版本 $VER）"
    echo "   系统总功率：${W} W"
    echo "   实时观察：  watch -n 0.1 sensors 'spbm-*'"
    echo "   功率通道：  ${DEV}/power1_input（sys_total，单位 µW）"
else
    echo
    echo "⚠️  模块已安装但未检测到 spbm hwmon 设备。"
    echo "   - 确认机型为 DGX Spark (GB10) 且 ACPI 设备 NVDA8800 存在"
    echo "   - 或重启后自动加载：sudo reboot"
    exit 1
fi

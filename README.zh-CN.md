# SPBM — DGX Spark 整机功率遥测与功耗上限控制驱动

[English](README.md) | **简体中文**

NVIDIA DGX Spark（GB10 SoC）的 Linux hwmon 驱动，通过标准 `sensors` / sysfs 接口
暴露**整机功率遥测**与**功耗上限控制**能力。

驱动读取 **SPBM（System Power Budget Manager）共享内存**——该区域由 MediaTek SSPM 固件
持续更新，包含毫瓦级功率、毫焦级累计能耗、摄氏百分度温度。其中 `pl1` / `pl2` /
`syspl1` / `syspl2` 四个通道提供可写的 `power_cap`，用于设置 OS 级功耗上限。

> **背景**：NVIDIA 官方曾表示 DGX Spark 上"没有监控 CPU 功耗的方法"。本驱动通过
> 逆向 DSDT 发现 SPBM 内存区域后实现，截至内核 7.0 尚无上游驱动。

> **建议**：先用 `fwupd` 更新 BIOS —— 旧固件可能对 CPU 功率通道上报错误数值。
> ```bash
> sudo fwupdmgr refresh && sudo fwupdmgr update
> ```
> SPBM 接口仍在演进，若发现数值异常或缺失，欢迎提 Issue。

---

## 本仓库相对上游的增强（v0.4.0）

| 改动 | 说明 |
|---|---|
| **能耗 64 位扩展** | 固件累计器是 32 位毫焦（上限约 **1.19 kWh**，GPU 满载约 12 小时即回绕）。驱动内部记录回绕基数，对外始终返回**单调递增的 64 位值**，平台统计不会出现跳变。 |
| **`power_average` 平滑值** | 固件用 100ms PID 控制环，瞬时功率会振荡。驱动为每个功率通道维护 EWMA（α=1/8），通过标准 hwmon `power{n}_average` 暴露平滑值。 |
| **映射大小取自 `_CRS`** | 不再硬编码 4KB，改用 ACPI `_CRS` 中 SPBM 资源的实际大小。 |
| **写入加锁** | `power_cap` 的"校验上下限 → 写入"改为原子操作，避免并发写竞争。 |
| **`MODULE_VERSION`** | 可通过 `modinfo spbm` 查看模块版本。 |

> 升级安装请用 `sudo ./install.sh`：脚本会先卸载内存中的旧模块，再加载新版本
> （直接 `modprobe` 不会替换已加载的模块）。

## 快速开始

### 一键安装（推荐）

```bash
git clone https://gitee.com/alexlu0912_admin/dgx_spark_hwmon.git
cd dgx_spark_hwmon
sudo ./install.sh
```

脚本会自动完成：安装依赖（`dkms` / `git` / 当前内核头文件）→ 清理残留 DKMS 状态 →
`dkms add / build / install` → `modprobe spbm` → 校验并打印系统总功率。

安装完成后：

```bash
# 找到 spbm 对应的 hwmon 设备
for d in /sys/class/hwmon/hwmon*; do
  [ "$(cat $d/name 2>/dev/null)" = "spbm" ] && echo "spbm -> $d"
done

# 实时观察全部通道
watch -n 0.1 sensors 'spbm-*'

# 直接读系统总功率（微瓦）
cat /sys/class/hwmon/hwmon8/power1_input
```

### 手动 DKMS 安装

```bash
sudo apt install dkms linux-headers-$(uname -r)

sudo dkms add .
VER=$(dkms status spbm | head -1 | sed -E 's#^spbm/([^,:]+).*#\1#')
sudo dkms build "spbm/$VER"
sudo dkms install "spbm/$VER"
sudo modprobe spbm
```

> 注意：`dkms status` 的输出形如 `spbm/0.3.0: added` 或
> `spbm/0.3.0, 6.17.0-1022-nvidia, aarch64: installed`，
> 版本号必须排除 `:` 与 `,`，否则会把状态串当成版本传给 dkms。

模块在开机时通过 ACPI modalias（`NVDA8800`）**自动加载**；DKMS 会在内核升级后**自动重建**。

### 卸载

```bash
sudo ./uninstall.sh
```

或手动：

```bash
dkms status spbm | awk -F'[,/]' '{print $2}' | xargs -I{} sudo dkms remove spbm/{} --all
sudo rmmod spbm
```

---

## 传感器一览

### 功率（14 通道）

| 通道 | 空载参考 | 说明 |
|---|---|---|
| `sys_total` | ~25 W | 整机总功率 |
| `soc_pkg` | ~17 W | SoC 封装 |
| `cpu_gpu` | ~6 W | CPU + GPU 合计 |
| `cpu_p` | ~0.5 W | P 核簇（10× Cortex-X925） |
| `cpu_e` | ~0.01 W | E 核簇（10× Cortex-A725） |
| `vcore` | ~4 W | 核心电压域 |
| `dc_input` | ~26 W | DC 输入 / 充电轨 |
| `gpu` | ~5 W | GPU 功率（与 `nvidia-smi` 一致） |
| `prereg` | ~8 W | 预稳压输入 |
| `dla` | ~0.1 W | 深度学习加速器 |
| `pl1` | ~18 W | PL1 控制器观测功率（max=250W，cap 可写） |
| `pl2` | ~18 W | PL2 控制器观测功率（max=250W，cap 可写） |
| `syspl1` | ~26 W | SysPL1 控制器观测功率（max=300W，cap 可写） |
| `syspl2` | ~27 W | SysPL2 控制器观测功率（max=300W，cap 可写） |

### 能耗（4 个累计器）

| 通道 | 说明 |
|---|---|
| `pkg` | 封装累计能耗 |
| `cpu_e` | E 核累计能耗 |
| `cpu_p` | P 核累计能耗 |
| `gpu` | GPU 累计能耗 |

> 计算平均值时，**能耗累计器比瞬时功率更准确**：固件使用 100ms PID 控制环，
> 瞬时值存在周期性抖动。

### 温度（8 个区域）

| 通道 | 空载参考 | 说明 |
|---|---|---|
| `tj_max` | ~31 °C | 封装 Tj 最高 |
| `cpu_e_clu0` | ~31 °C | E 核簇 0 |
| `cpu_p_clu0` | ~31 °C | P 核簇 0 |
| `cpu_e_clu1` | ~31 °C | E 核簇 1 |
| `cpu_p_clu1` | ~31 °C | P 核簇 1 |
| `gpu` | ~31 °C | GPU |
| `soc` | ~31 °C | SoC |
| `dla` | ~27 °C | DLA |

### 状态（自定义 sysfs）

| 属性 | 说明 |
|---|---|
| `prochot` | PROCHOT 热节流状态（0 = 正常） |
| `pl_level` | 当前生效的功耗限制档位 |
| `tj_max_c` | 相对环境的热升（分度，空载约 40） |

### 功耗上限控制（hwmon `power_cap`，可读写）

`pl1` / `pl2` / `syspl1` / `syspl2` 四个通道暴露标准 hwmon 属性（单位微瓦）：

- `power_cap`：**可读写**，当前生效上限（未设 OS 覆盖时为 EC 默认值）
- `power_max` / `power_min`：只读，来自固件 `LIMIT_HIGH` / `LIMIT_LOW` 寄存器（硬件绝对上下限）

超出 `power_min..power_max` 的写入会被拒绝；**写入 0 恢复 EC 默认值**。

```bash
# 把持续功耗限制到 100 W
echo 100000000 | sudo tee /sys/class/hwmon/hwmonN/power11_cap

# 恢复默认
echo 0 | sudo tee /sys/class/hwmon/hwmonN/power11_cap
```

> 满负载（20 核全开）参考：封装约 92 W、CPU_P 约 64 W、CPU_E 约 10.5 W。

---

## 在 LexData AI 平台中部署

平台「**一键部署**」页面已内置本驱动的安装入口（卡片：**可选增强 · 板级传感器**）：

1. 点击「检查状态」查看各节点是否已安装（显示版本、DKMS 状态、hwmon 设备数）
2. 点击「安装到所有节点」→ 实时显示每步命令与输出，完成后自动停止轮询

**源码分发方式**（适配无外网节点）：

```
Gitee ──(外网)──> head ──(RoCE :9100)──> worker
```

- **head** 从 Gitee 拉取源码（`action=sync-src`）
- **worker** 经 RoCE 从 head 下载源码包（`GET /spark-hwmon-src`），**无需访问外网**
- 令牌通过环境变量传递，不出现在日志中

安装后 `node-agent` 会**自动发现** `/sys/class/hwmon/*/name == "spbm"` 的设备，
**无需任何配置**，`#health-history` 页面即出现整机功率、各供电域功率、功耗上限与能耗区块；
未安装驱动的节点会自动隐藏这些区块，其余功能不受影响。

---

## 依赖要求

- NVIDIA DGX Spark（GB10 SoC），ACPI 设备 `NVDA8800`（MTEL）
- Linux 内核 **6.11+（ARM64）**
- 内核头文件 `linux-headers-$(uname -r)`
- DKMS
- 开启 Secure Boot 时需已注册的 MOK 密钥（默认 `/var/lib/shim-signed/mok/MOK.{priv,der}`，
  可用 `MOK_KEY=` / `MOK_CERT=` 覆盖）

## 手动编译（非 DKMS）

```bash
make            # 编译并签名（Secure Boot 需要 MOK 密钥）
sudo make load  # 编译、签名、加载模块并显示 sensors
make unload     # 卸载模块
make clean      # 清理构建产物
```

## 工作原理

驱动以 `acpi_driver` 形式绑定 `NVDA8800`（MTEL）ACPI 设备。probe 阶段调用设备的 `_DSM`
方法（UUID `12345678-1234-1234-1234-123456789abc`）：

1. **发现资源**（function 1）：在设备的 `_CRS` 资源中定位 SPBM 内存区域索引
2. **解析寄存器**（function 2）：将规范寄存器名映射到 SPBM 区域内的偏移，而非硬编码地址

因此固件更新导致内存布局变化时驱动依然可用；无法解析偏移的通道会被**自动隐藏**。

SPBM 区域由逆向 DSDT 发现，截至内核 7.0 无上游 Linux 驱动。

## 许可证

GPL-2.0

上游项目：<https://github.com/antheas/spark_hwmon>

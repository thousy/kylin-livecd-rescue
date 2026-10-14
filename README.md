# Kylin-Server-V10-SP3-Desktop-LiveCD

> 银河麒麟高级服务器操作系统 V10 SP3 企业级运维救援与数据恢复 LiveCD 自动化构建套件。

## 🌟 核心特性
- **纯净免密图形化桌面**：基于轻量 MATE 桌面，开机自动免密登录 root。
- **混合双模引导**：原生兼容 Legacy BIOS 与 UEFI 双引导架构。
- **动态 1080P 自适应**：开机自动检测屏幕并注入 1920x1080 模式，消除黑边。
- **LVM 逻辑卷支持**：自动激活卷组（`vgchange -ay`），完美识别国产系统 LVM 分区。
- **初学者安全防呆**：彻底移除“安装到硬盘”图标，集成坏道检测与一键远程协助。

## 🛠 桌面集成运维工具
1. 一键重置目标系统root密码
2. 一键修复GRUB与UEFI引导
3. 一键自动挂载所有硬盘
4. 磁盘分区管理 (GParted)
5. 打开原系统桌面
6. 文件管理器 (Caja)
7. 一键开启远程协助支持
8.1 硬盘健康快速诊断(SMART)
8.2 硬盘坏道全盘深度扫描(badblocks)
9. 安全重启电脑
10. 安全关机
11. 超级管理终端 (Root Terminal)

## 🚀 快速使用
在全新的 Kylin Server V10 SP3 宿主机上执行：
```bash
bash build_safe_desktop_livecd.sh

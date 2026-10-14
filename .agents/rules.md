# Antigravity Agent Guidelines for kylin-livecd-rescue

## 项目定位
本项目是针对“银河麒麟高级服务器系统 V10 SP3 (x86_64)”的企业级桌面运维救援 LiveCD 构建套件，面向非专业人员提供免密桌面、系统修复、引导重构及数据抢救。

## 核心安全准则（红线）
1. **宿主机安全第一**：绝不允许在宿主机上执行无挂载点的 `mkfs`、未经确认的 `dd` 或全局破坏性命令。
2. **清理与解挂**：任何对 `/mnt/live_rootfs` 的修改必须确保由 `trap cleanup EXIT` 处理，严禁残留未卸载的虚拟盘。
3. **防呆原则**：所有面向最终用户的运维脚本必须具备非破坏性检查（如数据恢复模式必须严格保持只读 `mount -o ro`）。
4. **依赖保持**：所有新增工具必须兼容 CentOS 8 Vault 归档源与麒麟 V10 SP3 原生包。

## 构建与测试
- 核心构建入口：`bash build_safe_desktop_livecd.sh`
- 最终产物位置：`/root/Kylin-Server-V10-SP3-Desktop-LiveCD.iso`

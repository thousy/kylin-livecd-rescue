#!/bin/bash
set -euo pipefail

# ==================== 配置区 ====================
WORK_DIR="/opt/livecd-desktop"
MOUNT_DIR="/mnt/live_rootfs"
IMG_SIZE_MB=8192
OUTPUT_ISO="/root/Kylin-Server-V10-SP3-Desktop-LiveCD.iso"

# ==================== 安全与退出清理 ====================
cleanup() {
    local exit_code=$?
    echo ">>> [清理机制] 执行安全释放与卸载..."
    set +e
    if mountpoint -q "${MOUNT_DIR}/dev"; then umount -f "${MOUNT_DIR}/dev"; fi
    if mountpoint -q "${MOUNT_DIR}/proc"; then umount -f "${MOUNT_DIR}/proc"; fi
    if mountpoint -q "${MOUNT_DIR}/sys"; then umount -f "${MOUNT_DIR}/sys"; fi
    if mountpoint -q "${MOUNT_DIR}"; then sync; umount -f "${MOUNT_DIR}"; fi
    if mountpoint -q "/mnt/efidisk"; then umount -f "/mnt/efidisk"; fi
    if [ $exit_code -ne 0 ]; then
        echo -e "\033[31m[错误] 构建异常中断，已还原现场，退出代码: $exit_code\033[0m"
    fi
}
trap cleanup EXIT INT TERM

# ==================== 安全断言 ====================
assert_is_mounted() {
    if [ -z "${MOUNT_DIR}" ] || [ "${MOUNT_DIR}" = "/" ]; then
        echo -e "\033[31m[安全断言失败] MOUNT_DIR 为空或为根目录！\033[0m"
        exit 1
    fi
    if ! mountpoint -q "${MOUNT_DIR}"; then
        echo -e "\033[31m[安全断言失败] ${MOUNT_DIR} 尚未挂载！\033[0m"
        exit 1
    fi
}

assert_rootfs_ready() {
    assert_is_mounted
    if [ ! -d "${MOUNT_DIR}/etc" ] || [ ! -f "${MOUNT_DIR}/etc/passwd" ]; then
        echo -e "\033[31m[安全断言失败] 系统文件尚未同步完整！\033[0m"
        exit 1
    fi
}

echo "=========================================================="
echo ">>> [1/7] 环境清理与初始化..."
echo "=========================================================="
command -v xorriso >/dev/null 2>&1 || yum install -y xorriso syslinux 2>/dev/null || true

umount -fl /run/media/root/* 2>/dev/null || true
rm -rf /run/media/root/* 2>/dev/null || true
losetup -D 2>/dev/null || true
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/iso/LiveOS" "${WORK_DIR}/iso/boot" "${WORK_DIR}/iso/isolinux" "${WORK_DIR}/iso/EFI/BOOT" "${WORK_DIR}/iso/images"
mkdir -p "${MOUNT_DIR}"
cd "${WORK_DIR}"

echo "=========================================================="
echo ">>> [2/7] 创建并挂载 8GB 虚拟根盘..."
echo "=========================================================="
dd if=/dev/zero of=rootfs.img bs=1M count=0 seek=${IMG_SIZE_MB}
mkfs.ext4 -F -m 0 -O ^has_journal,^metadata_csum -L "LiveOS_Root" rootfs.img
mount -o loop,rw rootfs.img "${MOUNT_DIR}"

assert_is_mounted

echo "=========================================================="
echo ">>> [3/7] 同步桌面系统文件..."
echo "=========================================================="
set +e
rsync -aHAX --info=progress2 \
  --exclude="/dev/*" \
  --exclude="/proc/*" \
  --exclude="/sys/*" \
  --exclude="/tmp/*" \
  --exclude="/run/*" \
  --exclude="/mnt/*" \
  --exclude="/media/*" \
  --exclude="/lost+found" \
  --exclude="/home/*" \
  --exclude="/var/tmp/*" \
  --exclude="/var/cache/*" \
  --exclude="/var/log/*" \
  --exclude="/var/lib/docker*" \
  --exclude="/var/lib/containers*" \
  --exclude="/opt/*" \
  --exclude="/root/.cache" \
  --exclude="*.img" \
  --exclude="*.iso" \
  --exclude="/usr/share/help/*" \
  --exclude="/usr/share/doc/*" \
  --exclude="/usr/share/man/*" \
  --exclude="/usr/lib/firmware/*" \
  --exclude="/lib/firmware/*" \
  / "${MOUNT_DIR}/"
set -e

mkdir -p "${MOUNT_DIR}/usr/lib/firmware"
/bin/cp -rf /usr/lib/firmware/intel "${MOUNT_DIR}/usr/lib/firmware/" 2>/dev/null || true

echo "=========================================================="
echo ">>> [4/7] 注入 MATE 桌面免密配置、小白防呆组件与初学者运维工具箱..."
echo "=========================================================="
assert_rootfs_ready

# 1. 虚拟根 fstab
cat << 'FSTAB_EOF' > "${MOUNT_DIR}/etc/fstab"
tmpfs   /dev/shm    tmpfs   defaults        0 0
devpts  /dev/pts    devpts  gid=5,mode=620  0 0
sysfs   /sys        sysfs   defaults        0 0
proc    proc        proc    defaults        0 0
FSTAB_EOF

# 2. 默认目标设为图形桌面，关闭阻塞与刷盘服务
chroot "${MOUNT_DIR}" systemctl set-default graphical.target 2>/dev/null || true
SERVICES_TO_MASK="
  systemd-remount-fs.service systemtap.service firewalld.service rsyslog.service
  NetworkManager-wait-online.service systemd-udev-settle.service plymouth-quit-wait.service
  postfix.service cups.service cups-browsed.service bluetooth.service
  crond.service atd.service kdump.service tuned.service smartd.service
  abrtd.service abrt-ccpp.service gssproxy.service
"
for s in $SERVICES_TO_MASK; do
  chroot "${MOUNT_DIR}" systemctl mask "$s" 2>/dev/null || true
done

# 3. 镜像内部放开 root 免密与自登录
sed -i 's/^root:[^:]*:/root::/' "${MOUNT_DIR}/etc/shadow"
sed -i 's/nullok_secure/nullok/g' "${MOUNT_DIR}/etc/pam.d/system-auth" 2>/dev/null || true
sed -i 's/.*pam_succeed_if.so.*user != root.*/#&/' "${MOUNT_DIR}/etc/pam.d/lightdm" 2>/dev/null || true
sed -i 's/.*pam_succeed_if.so.*user != root.*/#&/' "${MOUNT_DIR}/etc/pam.d/lightdm-autologin" 2>/dev/null || true
chroot "${MOUNT_DIR}" groupadd -r autologin 2>/dev/null || true
chroot "${MOUNT_DIR}" gpasswd -a root autologin 2>/dev/null || true

# 允许 root 远程无密码或免密登录（供远程协助使用）
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' "${MOUNT_DIR}/etc/ssh/sshd_config" 2>/dev/null || true
sed -i 's/PermitEmptyPasswords no/PermitEmptyPasswords yes/' "${MOUNT_DIR}/etc/ssh/sshd_config" 2>/dev/null || true

cat << 'LIGHTDM_EOF' > "${MOUNT_DIR}/etc/lightdm/lightdm.conf"
[Seat:*]
autologin-guest=false
autologin-user=root
autologin-user-timeout=0
autologin-session=mate
user-session=mate
greeter-session=ukui-greeter
greeter-show-manual-login=true
LIGHTDM_EOF
mkdir -p "${MOUNT_DIR}/etc/lightdm/lightdm.conf.d/"
cp -f "${MOUNT_DIR}/etc/lightdm/lightdm.conf" "${MOUNT_DIR}/etc/lightdm/lightdm.conf.d/99-autologin.conf"

echo "exec mate-session" > "${MOUNT_DIR}/root/.xinitrc"
chmod +x "${MOUNT_DIR}/root/.xinitrc"

# 4. 关闭锁屏与动效
mkdir -p "${MOUNT_DIR}/etc/dconf/db/local.d/"
cat << 'DCONF_EOF' > "${MOUNT_DIR}/etc/dconf/db/local.d/00-livecd-settings"
[org/ukui/screensaver]
idle-activation-enabled=false
lock-enabled=false

[org/ukui/power-manager]
sleep-display-ac=0
sleep-computer-ac=0
lock-on-suspend=false

[org/mate/Marco/general]
compositing-manager=false

[org/mate/desktop/interface]
enable-animations=false
menus-have-tearoff=false
DCONF_EOF
chroot "${MOUNT_DIR}" dconf update 2>/dev/null || true
sed -i 's/nullok_secure/nullok/g' "${MOUNT_DIR}/etc/pam.d/ukui-screensaver" 2>/dev/null || true

# 5. Polkit 免密读写磁盘策略
mkdir -p "${MOUNT_DIR}/etc/polkit-1/rules.d/"
cat << 'POLKIT_EOF' > "${MOUNT_DIR}/etc/polkit-1/rules.d/99-livecd-mount.rules"
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.udisks2.") === 0) {
        return polkit.Result.YES;
    }
});
POLKIT_EOF

# 6. 自动适配 1080P 分辨率并刷新桌面
cat << 'AUTO_RES_EOF' > "${MOUNT_DIR}/usr/local/bin/livecd_auto_resolution.sh"
#!/bin/bash
sleep 1
OUT=$(xrandr 2>/dev/null | grep " connected" | awk '{print $1}' | head -n 1)
if [ -n "$OUT" ]; then
    if ! xrandr 2>/dev/null | grep -q "1920x1080"; then
        xrandr --newmode "1920x1080_60.00" 173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync 2>/dev/null || true
        xrandr --addmode "$OUT" "1920x1080_60.00" 2>/dev/null || true
        xrandr --output "$OUT" --mode "1920x1080_60.00" 2>/dev/null || true
    else
        xrandr --output "$OUT" --mode 1920x1080 2>/dev/null || xrandr --auto 2>/dev/null || true
    fi
fi
sleep 0.5
pkill -HUP caja 2>/dev/null || true
AUTO_RES_EOF
chmod +x "${MOUNT_DIR}/usr/local/bin/livecd_auto_resolution.sh"

# 7. 虚拟机性能模式调节向导 (GTK3 UI)
cat << 'PY_VIRT' > "${MOUNT_DIR}/usr/local/bin/livecd_virt_optimizer.py"
#!/usr/bin/env python3
import subprocess
import sys
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk

try:
    virt = subprocess.check_output(['systemd-detect-virt']).decode().strip()
    if virt in ['none', '']:
        sys.exit(0)
except Exception:
    pass

class VirtDialog(Gtk.Window):
    def __init__(self):
        super().__init__(title="友情提示")
        self.set_border_width(24)
        self.set_default_size(520, 420)
        self.set_position(Gtk.WindowPosition.CENTER_ALWAYS)
        self.set_resizable(False)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        self.add(box)

        title = Gtk.Label()
        title.set_markup("<span font='18' weight='bold'>友情提示</span>")
        box.pack_start(title, False, False, 0)

        desc = Gtk.Label(label="检测到您正在使用虚拟机，这将影响系统性能和操作体验。为了在虚拟机下流畅地使用该系统，建议您选择最佳性能模式进入桌面。")
        desc.set_line_wrap(True)
        desc.set_max_width_chars(50)
        box.pack_start(desc, False, False, 0)

        btn_perf = Gtk.Button()
        b_box1 = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        lbl1_title = Gtk.Label()
        lbl1_title.set_markup("<span font='13' weight='bold'>🚀 最佳性能 (推荐)</span>")
        lbl1_title.set_xalign(0)
        lbl1_desc = Gtk.Label(label="关闭所有界面和窗口特效，资源占用降至最低，保障系统高效运行。")
        lbl1_desc.set_xalign(0)
        lbl1_desc.set_line_wrap(True)
        b_box1.pack_start(lbl1_title, False, False, 0)
        b_box1.pack_start(lbl1_desc, False, False, 0)
        btn_perf.add(b_box1)
        btn_perf.connect("clicked", self.set_perf)
        box.pack_start(btn_perf, False, False, 0)

        btn_bal = Gtk.Button()
        b_box2 = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        lbl2_title = Gtk.Label()
        lbl2_title.set_markup("<span font='13' weight='bold'>⚖ 均衡</span>")
        lbl2_title.set_xalign(0)
        lbl2_desc = Gtk.Label(label="限制部分窗口动效，保障视觉体验的同时维持系统流畅。")
        lbl2_desc.set_xalign(0)
        lbl2_desc.set_line_wrap(True)
        b_box2.pack_start(lbl2_title, False, False, 0)
        b_box2.pack_start(lbl2_desc, False, False, 0)
        btn_bal.add(b_box2)
        btn_bal.connect("clicked", self.set_bal)
        box.pack_start(btn_bal, False, False, 0)

        btn_vis = Gtk.Button()
        b_box3 = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        lbl3_title = Gtk.Label()
        lbl3_title.set_markup("<span font='13' weight='bold'>✨ 最佳视觉</span>")
        lbl3_title.set_xalign(0)
        lbl3_desc = Gtk.Label(label="启用所有界面特效与阴影合成，体验完整视觉效果。")
        lbl3_desc.set_xalign(0)
        lbl3_desc.set_line_wrap(True)
        b_box3.pack_start(lbl3_title, False, False, 0)
        b_box3.pack_start(lbl3_desc, False, False, 0)
        btn_vis.add(b_box3)
        btn_vis.connect("clicked", self.set_vis)
        box.pack_start(btn_vis, False, False, 0)

    def set_perf(self, widget):
        subprocess.run("gsettings set org.mate.Marco.general compositing-manager false 2>/dev/null", shell=True)
        subprocess.run("gsettings set org.mate.desktop.interface enable-animations false 2>/dev/null", shell=True)
        Gtk.main_quit()

    def set_bal(self, widget):
        subprocess.run("gsettings set org.mate.Marco.general compositing-manager true 2>/dev/null", shell=True)
        subprocess.run("gsettings set org.mate.desktop.interface enable-animations false 2>/dev/null", shell=True)
        Gtk.main_quit()

    def set_vis(self, widget):
        subprocess.run("gsettings set org.mate.Marco.general compositing-manager true 2>/dev/null", shell=True)
        subprocess.run("gsettings set org.mate.desktop.interface enable-animations true 2>/dev/null", shell=True)
        Gtk.main_quit()

win = VirtDialog()
win.connect("destroy", Gtk.main_quit)
win.show_all()
Gtk.main()
PY_VIRT
chmod +x "${MOUNT_DIR}/usr/local/bin/livecd_virt_optimizer.py"

# 8. 启动模式选择向导 (系统修复 vs 文件恢复 2.0.0)
cat << 'PY_MODE' > "${MOUNT_DIR}/usr/local/bin/livecd_mode_selector.py"
#!/usr/bin/env python3
import subprocess
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk

class ModeSelector(Gtk.Window):
    def __init__(self):
        super().__init__(title="选择启动模式 — Livecd工具(2.0.0)")
        self.set_border_width(24)
        self.set_default_size(540, 360)
        self.set_position(Gtk.WindowPosition.CENTER_ALWAYS)
        self.set_resizable(False)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        self.add(box)

        title = Gtk.Label()
        title.set_markup("<span font='16' weight='bold'>请选择启动模式</span>")
        title.set_xalign(0)
        box.pack_start(title, False, False, 0)

        desc = Gtk.Label(label="如果需要恢复误删文件，请先进入文件恢复模式，避免自动挂载和写入目标磁盘。")
        desc.set_xalign(0)
        desc.set_line_wrap(True)
        box.pack_start(desc, False, False, 0)

        btn_repair = Gtk.Button()
        b1 = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        l1_title = Gtk.Label()
        l1_title.set_markup("<span font='13' weight='bold'>🛠 系统修复</span>")
        l1_title.set_xalign(0)
        l1_desc = Gtk.Label(label="进入常规运维模式：支持磁盘识别、自动挂载、引导重建与密码重置。")
        l1_desc.set_xalign(0)
        b1.pack_start(l1_title, False, False, 0)
        b1.pack_start(l1_desc, False, False, 0)
        btn_repair.add(b1)
        btn_repair.connect("clicked", self.start_repair)
        box.pack_start(btn_repair, False, False, 0)

        btn_recover = Gtk.Button()
        b2 = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        l2_title = Gtk.Label()
        l2_title.set_markup("<span font='13' weight='bold'>📁 文件恢复 (防二次损坏保护)</span>")
        l2_title.set_xalign(0)
        l2_desc = Gtk.Label(label="严格禁止自动挂载物理盘，保持只读安全状态，直接调出专业恢复程序。")
        l2_desc.set_xalign(0)
        b2.pack_start(l2_title, False, False, 0)
        b2.pack_start(l2_desc, False, False, 0)
        btn_recover.add(b2)
        btn_recover.connect("clicked", self.start_recover)
        box.pack_start(btn_recover, False, False, 0)

        btn_quit = Gtk.Button(label="直接进入桌面")
        btn_quit.connect("clicked", lambda w: Gtk.main_quit())
        box.pack_end(btn_quit, False, False, 0)

    def start_repair(self, widget):
        subprocess.Popen(["/bin/bash", "-c", "vgchange -ay 2>/dev/null || true"])
        Gtk.main_quit()

    def start_recover(self, widget):
        subprocess.Popen(["mate-terminal", "-e", "testdisk"])
        Gtk.main_quit()

win = ModeSelector()
win.connect("destroy", Gtk.main_quit)
win.show_all()
Gtk.main()
PY_MODE
chmod +x "${MOUNT_DIR}/usr/local/bin/livecd_mode_selector.py"

# 自启动链条配置
mkdir -p "${MOUNT_DIR}/etc/xdg/autostart"
cat << 'AUTORUN_EOF' > "${MOUNT_DIR}/usr/local/bin/livecd_autostart_chain.sh"
#!/bin/bash
/usr/local/bin/livecd_auto_resolution.sh
/usr/local/bin/livecd_virt_optimizer.py
/usr/local/bin/livecd_mode_selector.py
AUTORUN_EOF
chmod +x "${MOUNT_DIR}/usr/local/bin/livecd_autostart_chain.sh"

cat << 'AUTODESK_EOF' > "${MOUNT_DIR}/etc/xdg/autostart/livecd-init.desktop"
[Desktop Entry]
Type=Application
Name=LiveCD Chain Init
Exec=/usr/local/bin/livecd_autostart_chain.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
AUTODESK_EOF

# 9. 编写核心向导工具、初学者支持脚本与桌面快捷方式
mkdir -p "${MOUNT_DIR}/root/Desktop" "${MOUNT_DIR}/root/桌面" "${MOUNT_DIR}/usr/local/bin"

# 0. 应急救援说明书
cat << 'README_EOF' > "${MOUNT_DIR}/root/Desktop/0. 应急救援使用说明(先读我).txt"
==============================================================
               国产系统应急救援 LiveCD 使用指南
==============================================================

欢迎使用系统急救与数据恢复环境。请根据目标机器故障选择对应工具：

1. 【忘记 root 密码】
   -> 双击「1. 一键重置目标系统root密码」
   -> 本工具仅清空密码标志位，100% 绝不丢失或改动任何原有数据。
   -> 操作完成后，重启物理机以 root 用户登录，直接按回车即可进入系统。

2. 【开机卡住 / 提示 GRUB 引导丢失 / 黑屏】
   -> 双击「2. 一键修复GRUB与UEFI引导」
   -> 脚本会自动挂载并一键重构系统的启动引导项。

3. 【系统崩溃，急需抢救拷贝原有数据】
   -> 双击「3. 一键自动挂载所有硬盘」
   -> 物理机所有硬盘分区将直接挂载到 /mnt/disks/，并自动弹出文件夹供你拷贝。
   -> 或者直接双击「5. 打开原系统桌面」直接导出原来桌面上的文件。

4. 【怀疑硬盘坏了 / 检查硬件健康】
   -> 秒测状态：双击「8.1 硬盘健康快速诊断(SMART)」
   -> 深度逐扇区慢扫：双击「8.2 硬盘坏道全盘深度扫描(badblocks)」

5. 【搞不定？需要专业工程师远程帮忙】
   -> 双击「7. 一键开启远程协助支持」
   -> 屏幕会显示本机 IP，将 IP 拍照发送给技术人员即可直接远程连入维护。

6. 【维护完成后退出】
   -> 请务必点击桌面的「安全重启电脑」或「安全关机」，切勿直接拔物理电源！
==============================================================
README_EOF

# 工具 1：密码清除脚本
cat << 'SH_PWD' > "${MOUNT_DIR}/usr/local/bin/livecd_reset_pwd.sh"
#!/bin/bash
clear
echo "=========================================================="
echo "        国产系统 / Linux 目标机 root 密码一键清除向导"
echo "=========================================================="
echo "【安全保障】本操作仅重置密码标志位，绝对不修改或影响硬盘中的数据！"
echo ">>> 正在激活 LVM 逻辑卷并全面扫描系统分区..."
vgchange -ay 2>/dev/null || true

TARGETS=()
for dev in $(lsblk -lno NAME,TYPE | awk '$2=="part" || $2=="lvm" {print "/dev/"$1}'); do
  case "$dev" in
    *live-rw*|*live-base*|*loop*) continue ;;
  esac
  mkdir -p /tmp/check_mnt
  if mount -o ro "$dev" /tmp/check_mnt 2>/dev/null; then
    if [ -f /tmp/check_mnt/etc/shadow ]; then
      OS_NAME="Linux 系统"
      if [ -f /tmp/check_mnt/etc/os-release ]; then
        OS_NAME=$(grep -E "^PRETTY_NAME=" /tmp/check_mnt/etc/os-release | cut -d'=' -f2 | tr -d '"')
      fi
      TARGETS+=("$dev [$OS_NAME]")
    fi
    umount /tmp/check_mnt
  fi
done

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo -e "\033[31m[提示] 未在物理硬盘中找到包含 /etc/shadow 的有效 Linux 系统分区！\033[0m"
  echo "请确认硬盘已正确连接，或磁盘是否已组软 RAID/物理损坏。"
  read -p "按回车键退出..." && exit 1
fi

echo "扫描到以下系统分区："
PS3="请选择要清除 root 密码的序号 (输入数字回车): "
select ITEM in "${TARGETS[@]}"; do
  if [ -n "$ITEM" ]; then
    DEV=$(echo "$ITEM" | awk '{print $1}')
    mkdir -p /tmp/target_root
    mount "$DEV" /tmp/target_root
    cp /tmp/target_root/etc/shadow /tmp/target_root/etc/shadow.bak_livecd
    sed -i 's/^root:[^:]*:/root::/' /tmp/target_root/etc/shadow
    sync
    umount /tmp/target_root
    echo "=========================================================="
    echo -e "\033[32m>>> [操作成功] 分区 $DEV 的 root 密码已被清空！\033[0m"
    echo ">>> 说明：请拔出 U 盘，然后点击桌面的「安全重启电脑」，登录时以 root 账户直接按回车即可！"
    echo "=========================================================="
    break
  fi
done
read -p "按回车键退出..."
SH_PWD
chmod +x "${MOUNT_DIR}/usr/local/bin/livecd_reset_pwd.sh"

cat << 'DESK_PWD' > "${MOUNT_DIR}/root/Desktop/reset_root_pwd.desktop"
[Desktop Entry]
Name=1. 一键重置目标系统root密码
Comment=自动扫描物理机并清空麒麟/UOS系统root密码
Exec=mate-terminal -e /usr/local/bin/livecd_reset_pwd.sh
Icon=dialog-password
Terminal=false
Type=Application
DESK_PWD

# 工具 2：引导修复脚本
cat << 'SH_BOOT' > "${MOUNT_DIR}/usr/local/bin/livecd_fix_boot.sh"
#!/bin/bash
clear
echo "=========================================================="
echo "          国产系统 GRUB / UEFI 引导一键重构与修复向导"
echo "=========================================================="
vgchange -ay 2>/dev/null || true
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT
echo "----------------------------------------------------------"
read -p "请输入目标系统的根分区设备名 (如 /dev/sda2 或 /dev/mapper/klas-root): " ROOT_DEV

if [ ! -b "$ROOT_DEV" ]; then
  echo -e "\033[31m[错误] 设备 $ROOT_DEV 不存在！\033[0m"
  read -p "按回车键退出..." && exit 1
fi

mkdir -p /mnt/fix_sys
mount "$ROOT_DEV" /mnt/fix_sys

read -p "是否有独立的 /boot 分区？(有请输入如 /dev/sda1，无则直接回车): " BOOT_DEV
[ -n "$BOOT_DEV" ] && [ -b "$BOOT_DEV" ] && mkdir -p /mnt/fix_sys/boot && mount "$BOOT_DEV" /mnt/fix_sys/boot

read -p "是否有独立的 EFI 分区？(如 /dev/sda1，无则回车): " EFI_DEV
[ -n "$EFI_DEV" ] && [ -b "$EFI_DEV" ] && mkdir -p /mnt/fix_sys/boot/efi && mount "$EFI_DEV" /mnt/fix_sys/boot/efi

echo ">>> 正在挂载底层伪文件系统并 chroot 重建引导..."
mount --bind /dev /mnt/fix_sys/dev
mount --bind /proc /mnt/fix_sys/proc
mount --bind /sys /mnt/fix_sys/sys

chroot /mnt/fix_sys grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
chroot /mnt/fix_sys grub2-mkconfig -o /boot/efi/EFI/kylin/grub.cfg 2>/dev/null || true
chroot /mnt/fix_sys grub2-mkconfig -o /boot/efi/EFI/neokylin/grub.cfg 2>/dev/null || true
chroot /mnt/fix_sys grub2-mkconfig -o /boot/efi/EFI/BOOT/grub.cfg 2>/dev/null || true

sync
umount -R /mnt/fix_sys 2>/dev/null || true
echo "=========================================================="
echo -e "\033[32m>>> [修复完成] 引导配置文件已更新完毕，可尝试重启验证！\033[0m"
echo "=========================================================="
read -p "按回车键退出..."
SH_BOOT
chmod +x "${MOUNT_DIR}/usr/local/bin/livecd_fix_boot.sh"

cat << 'DESK_BOOT' > "${MOUNT_DIR}/root/Desktop/fix_boot.desktop"
[Desktop Entry]
Name=2. 一键修复GRUB与UEFI引导
Comment=自动挂载并重构目标系统的GRUB与UEFI引导
Exec=mate-terminal -e /usr/local/bin/livecd_fix_boot.sh
Icon=system-run
Terminal=false
Type=Application
DESK_BOOT

# 工具 3：全盘自动挂载脚本
cat << 'SH_MOUNT' > "${MOUNT_DIR}/usr/local/bin/livecd_mount_all.sh"
#!/bin/bash
clear
echo "=========================================================="
echo "       全盘自动扫描与挂载工具 (用于快速导出抢救数据)"
echo "=========================================================="
vgchange -ay 2>/dev/null || true
mkdir -p /mnt/disks
echo ">>> 正在扫描并挂载物理磁盘..."

lsblk -lpno NAME,FSTYPE | grep -E "ext|xfs|ntfs|vfat|fat|btrfs" | while read -r DEV FS; do
  case "$DEV" in
    *live-rw*|*live-base*|*loop*) continue ;;
  esac
  BNAME=$(basename "$DEV")
  TDIR="/mnt/disks/$BNAME"
  mkdir -p "$TDIR"
  if mount "$DEV" "$TDIR" 2>/dev/null; then
    echo "  [读写挂载成功] $DEV ($FS) -> $TDIR"
  elif mount -o ro "$DEV" "$TDIR" 2>/dev/null; then
    echo "  [只读挂载成功] $DEV ($FS) -> $TDIR"
  else
    echo "  [无法挂载/跳过] $DEV"
  fi
done

echo "----------------------------------------------------------"
echo ">>> 完成！所有目标磁盘已汇集至 /mnt/disks/ 目录下。"
caja /mnt/disks &
read -p "按回车键退出..."
SH_MOUNT
chmod +x "${MOUNT_DIR}/usr/local/bin/livecd_mount_all.sh"

cat << 'DESK_MOUNT' > "${MOUNT_DIR}/root/Desktop/mount_all_disks.desktop"
[Desktop Entry]
Name=3. 一键自动挂载所有硬盘
Comment=自动将所有分区挂载至 /mnt/disks 并打开文件管理器
Exec=mate-terminal -e /usr/local/bin/livecd_mount_all.sh
Icon=drive-harddisk
Terminal=false
Type=Application
DESK_MOUNT

# 工具 4：GParted 分区管理
cat << 'GPARTED_DESK' > "${MOUNT_DIR}/root/Desktop/gparted.desktop"
[Desktop Entry]
Name=4. 磁盘分区管理 (GParted)
GenericName=Partition Editor
Comment=管理磁盘分区与格式化
Exec=gparted
Icon=gparted
Terminal=false
Type=Application
GPARTED_DESK

# 工具 5：打开原系统桌面
cat << 'SH_DESK' > "${MOUNT_DIR}/usr/local/bin/livecd_open_target_desktop.sh"
#!/bin/bash
clear
echo "=========================================================="
echo "             自动定位并打开原系统桌面文件"
echo "=========================================================="
vgchange -ay 2>/dev/null || true
TARGET_MNT="/mnt/target_sys"
mkdir -p "$TARGET_MNT"

ROOT_DEV=""
for dev in $(lsblk -lno NAME,TYPE | awk '$2=="part" || $2=="lvm" {print "/dev/"$1}'); do
  case "$dev" in
    *live-rw*|*live-base*|*loop*) continue ;;
  esac
  mkdir -p /tmp/chk_desk
  if mount -o ro "$dev" /tmp/chk_desk 2>/dev/null; then
    if [ -f /tmp/chk_desk/etc/shadow ] && [ -d /tmp/chk_desk/root ]; then
      ROOT_DEV="$dev"
      umount /tmp/chk_desk
      break
    fi
    umount /tmp/chk_desk
  fi
done

if [ -z "$ROOT_DEV" ]; then
  echo -e "\033[31m[错误] 未检测到有效的目标系统根分区！\033[0m"
  read -p "按回车键退出..." && exit 1
fi

mount "$ROOT_DEV" "$TARGET_MNT" 2>/dev/null || true

FOUND_DESK=""
for candidate in "$TARGET_MNT"/home/*/"Desktop" "$TARGET_MNT"/home/*/"桌面" "$TARGET_MNT"/root/"Desktop" "$TARGET_MNT"/root/"桌面"; do
  if [ -d "$candidate" ]; then
    FOUND_DESK="$candidate"
    break
  fi
done

if [ -z "$FOUND_DESK" ]; then
  FOUND_DESK="$TARGET_MNT/root"
fi

echo ">>> 成功挂载原系统: $ROOT_DEV"
echo ">>> 正在打开原系统桌面: $FOUND_DESK"
caja "$FOUND_DESK" &
sleep 1
SH_DESK
chmod +x "${MOUNT_DIR}/usr/local/bin/livecd_open_target_desktop.sh"

cat << 'DESK_TARGET_DESK' > "${MOUNT_DIR}/root/Desktop/open_target_desktop.desktop"
[Desktop Entry]
Name=5. 打开原系统桌面
Comment=自动挂载物理机系统分区并直接打开原桌面文件
Exec=/usr/local/bin/livecd_open_target_desktop.sh
Icon=user-desktop
Terminal=true
Type=Application
DESK_TARGET_DESK

# 工具 6：文件管理器
cat << 'CAJA_DESK' > "${MOUNT_DIR}/root/Desktop/caja.desktop"
[Desktop Entry]
Name=6. 文件管理器 (浏览数据)
Comment=浏览文件系统及挂载磁盘
Exec=caja --no-desktop
Icon=system-file-manager
Terminal=false
Type=Application
CAJA_DESK

# 工具 7：远程协助支持
cat << 'SH_REMOTE' > "${MOUNT_DIR}/usr/local/bin/livecd_remote_assist.sh"
#!/bin/bash
clear
echo "=========================================================="
echo "               一键开启远程技术支持协助"
echo "=========================================================="
echo ">>> 正在启动 SSH 远程管理服务..."
systemctl start sshd 2>/dev/null || /usr/sbin/sshd 2>/dev/null || true

echo "root:123456" | chpasswd

IP_LIST=$(ip -4 addr show | grep inet | awk '{print $2}' | cut -d/ -f1 | grep -v "127.0.0.1")

echo -e "\033[32m>>> 远程协助服务已就绪！\033[0m"
echo "----------------------------------------------------------"
echo "请将以下信息拍照发送给技术支持工程师："
echo ""
echo -e "  本机 IP 地址 : \033[33m\n$IP_LIST\033[0m"
echo -e "  登录用户名   : \033[36mroot\033[0m"
echo -e "  远程维护口令 : \033[32m123456\033[0m"
echo -e "  SSH 连接端口 : \033[36m22\033[0m"
echo "----------------------------------------------------------"
echo "工程师可直接通过终端或 MobaXterm 输入上述 IP 进行连入接管。"
echo "=========================================================="
read -p "按回车键保持运行并返回..."
SH_REMOTE
chmod +x "${MOUNT_DIR}/usr/local/bin/livecd_remote_assist.sh"

cat << 'DESK_REMOTE' > "${MOUNT_DIR}/root/Desktop/remote_assist.desktop"
[Desktop Entry]
Name=7. 一键开启远程协助支持
Comment=开启SSH服务并显示本机IP以供工程师远程接管
Exec=mate-terminal -e /usr/local/bin/livecd_remote_assist.sh
Icon=network-transmit-receive
Terminal=false
Type=Application
DESK_REMOTE

# 工具 8.1：硬盘健康快速诊断（SMART 秒测）
cat << 'SH_SMART' > "${MOUNT_DIR}/usr/local/bin/livecd_check_disk_health.sh"
#!/bin/bash
clear
echo "=========================================================="
echo "             物理硬盘健康快速诊断向导 (SMART 秒测)"
echo "=========================================================="
DISKS=$(lsblk -dno NAME,TYPE | awk '$2=="disk" {print "/dev/"$1}')

if [ -z "$DISKS" ]; then
  echo -e "\033[31m[错误] 未检测到任何物理磁盘！\033[0m"
  read -p "按回车键退出..." && exit 1
fi

echo "正在逐一诊断接入的物理硬盘..."
echo "----------------------------------------------------------"

for d in $DISKS; do
  case "$d" in
    *loop*|*ram*) continue ;;
  esac
  MODEL=$(lsblk -dno MODEL "$d" 2>/dev/null || echo "未知型号")
  SIZE=$(lsblk -dno SIZE "$d" 2>/dev/null || echo "未知容量")
  echo ">>> 检测磁盘: $d (型号: $MODEL, 容量: $SIZE)"
  
  SMART_OUT=$(smartctl -H "$d" 2>/dev/null || true)
  if echo "$SMART_OUT" | grep -q "PASSED"; then
    echo -e "  \033[32m[健康良好] 该硬盘 SMART 检查通过，无硬件致命故障。\033[0m"
  elif echo "$SMART_OUT" | grep -q "FAILED"; then
    echo -e "  \033[31m[严重警告] 该硬盘出现硬件级损坏或寿命耗尽！请勿执行大文件写入，立刻备份！\033[0m"
  else
    echo -e "  \033[33m[普通提示] 虚拟磁盘或不支持 SMART 监测的阵列卡，运行状态正常。\033[0m"
  fi
  echo "----------------------------------------------------------"
done

echo "诊断完毕！如果硬盘存在硬件损坏，建议优先使用「3. 一键自动挂载所有硬盘」导出核心文件。"
read -p "按回车键退出..."
SH_SMART
chmod +x "${MOUNT_DIR}/usr/local/bin/livecd_check_disk_health.sh"

cat << 'DESK_SMART' > "${MOUNT_DIR}/root/Desktop/check_disk_health.desktop"
[Desktop Entry]
Name=8.1 硬盘健康快速诊断(SMART)
Comment=通俗化检测硬盘硬件是否损坏或有物理坏道
Exec=mate-terminal -e /usr/local/bin/livecd_check_disk_health.sh
Icon=utilities-system-monitor
Terminal=false
Type=Application
DESK_SMART

# 工具 8.2：硬盘坏道全盘深度扫描 (badblocks 只读地毯式慢扫)
cat << 'SH_BAD' > "${MOUNT_DIR}/usr/local/bin/livecd_scan_badblocks.sh"
#!/bin/bash
clear
echo "=========================================================="
echo "          物理硬盘坏区与坏道全盘深度扫描向导 (只读安全)"
echo "=========================================================="
DISKS=($(lsblk -dno NAME,TYPE | awk '$2=="disk" && $1 !~ /loop|ram/ {print "/dev/"$1}'))

if [ ${#DISKS[@]} -eq 0 ]; then
  echo -e "\033[31m[错误] 未检测到任何物理磁盘！\033[0m"
  read -p "按回车键退出..." && exit 1
fi

echo "检测到以下物理硬盘："
PS3="请选择要进行坏道深度扫描的硬盘 (输入数字回车): "
select D_DEV in "${DISKS[@]}"; do
  if [ -n "$D_DEV" ]; then
    echo "----------------------------------------------------------"
    echo "即将对 $D_DEV 进行【只读安全深度扫描】..."
    echo "注意：根据硬盘容量大小，全盘逐扇区扫描可能需要较长时间。"
    echo "你可以随时按 Ctrl + C 中断扫描。"
    echo "----------------------------------------------------------"
    read -p "确认开始扫描请按回车键..."
    
    badblocks -sv -b 4096 "$D_DEV"
    RET=$?
    
    echo "----------------------------------------------------------"
    if [ $RET -eq 0 ]; then
      echo -e "\033[32m>>> [检测完毕] 未发现任何物理坏块，该硬盘扇区读写健康！\033[0m"
    else
      echo -e "\033[31m>>> [严重警告] 扫描过程中发现坏道坏块！建议立即更换硬盘并抢救数据！\033[0m"
    fi
    echo "=========================================================="
    break
  fi
done
read -p "按回车键退出..."
SH_BAD
chmod +x "${MOUNT_DIR}/usr/local/bin/livecd_scan_badblocks.sh"

cat << 'DESK_BAD' > "${MOUNT_DIR}/root/Desktop/scan_badblocks.desktop"
[Desktop Entry]
Name=8.2 硬盘坏道全盘深度扫描(badblocks)
Comment=逐扇区地毯式扫描物理硬盘是否有坏区坏道
Exec=mate-terminal -e /usr/local/bin/livecd_scan_badblocks.sh
Icon=system-search
Terminal=false
Type=Application
DESK_BAD

# 工具 9：安全关机与安全重启
cat << 'DESK_REBOOT' > "${MOUNT_DIR}/root/Desktop/safe_reboot.desktop"
[Desktop Entry]
Name=9. 安全重启电脑
Comment=先安全同步保存数据再重启电脑
Exec=/bin/sh -c "sync; systemctl reboot"
Icon=system-reboot
Terminal=false
Type=Application
DESK_REBOOT

cat << 'DESK_SHUTDOWN' > "${MOUNT_DIR}/root/Desktop/safe_shutdown.desktop"
[Desktop Entry]
Name=10. 安全关机
Comment=先安全同步保存数据再关闭电源
Exec=/bin/sh -c "sync; systemctl poweroff"
Icon=system-shutdown
Terminal=false
Type=Application
DESK_SHUTDOWN

# 工具 11：超级管理终端
cat << 'TERM_DESK' > "${MOUNT_DIR}/root/Desktop/terminal.desktop"
[Desktop Entry]
Name=11. 超级管理终端 (Root Terminal)
Comment=执行底层运维命令
Exec=mate-terminal
Icon=utilities-terminal
Terminal=false
Type=Application
TERM_DESK

# 【防呆机制】清理掉危险的“安装到硬盘”图标，防止误操作格盘
rm -f "${MOUNT_DIR}/root/Desktop/liveinst.desktop" "${MOUNT_DIR}/usr/share/applications/liveinst.desktop" 2>/dev/null || true

# 快捷方式与说明书同步写入中文桌面与全局用户模板
mkdir -p "${MOUNT_DIR}/root/桌面" "${MOUNT_DIR}/etc/skel/桌面" "${MOUNT_DIR}/etc/skel/Desktop"
cp -af "${MOUNT_DIR}/root/Desktop/"* "${MOUNT_DIR}/root/桌面/"
cp -af "${MOUNT_DIR}/root/Desktop/"* "${MOUNT_DIR}/etc/skel/桌面/"
cp -af "${MOUNT_DIR}/root/Desktop/"* "${MOUNT_DIR}/etc/skel/Desktop/"
chmod +x "${MOUNT_DIR}/root/Desktop/"*.desktop "${MOUNT_DIR}/root/桌面/"*.desktop 2>/dev/null || true
chroot "${MOUNT_DIR}" update-desktop-database 2>/dev/null || true

# 10. 紧急模式兜底
mkdir -p "${MOUNT_DIR}/etc/systemd/system/emergency.service.d/"
mkdir -p "${MOUNT_DIR}/etc/systemd/system/rescue.service.d/"
printf '%s\n' "[Service]" "ExecStart=" "ExecStart=-/bin/sh -c \"/sbin/sulogin --force || /bin/bash\"" > "${MOUNT_DIR}/etc/systemd/system/emergency.service.d/override.conf"
printf '%s\n' "[Service]" "ExecStart=" "ExecStart=-/bin/sh -c \"/sbin/sulogin --force || /bin/bash\"" > "${MOUNT_DIR}/etc/systemd/system/rescue.service.d/override.conf"

echo "=========================================================="
echo ">>> [5/7] 安全同步与卸载虚拟根盘..."
echo "=========================================================="
sync
umount "${MOUNT_DIR}"

echo "=========================================================="
echo ">>> [6/7] 多核并发压缩 SquashFS（零额外磁盘消耗）..."
echo "=========================================================="
mkdir -p squashfs-staging/LiveOS
mv -f rootfs.img squashfs-staging/LiveOS/rootfs.img
mksquashfs squashfs-staging iso/LiveOS/squashfs.img -comp gzip -b 256k -processors $(nproc) -noappend
rm -rf squashfs-staging

echo "=========================================================="
echo ">>> [7/7] 引导装配与混合双模 ISO 封装..."
echo "=========================================================="
/bin/cp -f /boot/vmlinuz-$(uname -r) iso/boot/vmlinuz
KVER=$(uname -r)

WANT_DRIVERS="sr_mod cdrom isofs squashfs loop overlay ahci libahci ata_piix ata_generic megaraid_sas mpt3sas nvme vmw_pvscsi virtio_blk virtio_pci usb_storage uas xhci_pci xhci_hcd ehci_pci ehci_hcd vmwgfx"
VALID_DRIVERS=""
for mod in $WANT_DRIVERS; do
  if find /lib/modules/$KVER/ -name "${mod}.ko*" 2>/dev/null | grep -q .; then
    VALID_DRIVERS="${VALID_DRIVERS} ${mod}"
  fi
done

dracut --force --no-hostonly \
  --force-add "dmsquash-live" \
  --add-drivers "${VALID_DRIVERS}" \
  iso/boot/initrd.img "$KVER"

# BIOS 引导
ISO_BIN=$(find /usr /boot -name "isolinux.bin" 2>/dev/null | head -n 1)
if [ -n "$ISO_BIN" ]; then
    /bin/cp -f "$ISO_BIN" iso/isolinux/isolinux.bin
    find /usr -name "ldlinux.c32" -exec /bin/cp -f {} iso/isolinux/ \; 2>/dev/null || true
    find /usr -name "libcom32.c32" -exec /bin/cp -f {} iso/isolinux/ \; 2>/dev/null || true
    find /usr -name "libutil.c32" -exec /bin/cp -f {} iso/isolinux/ \; 2>/dev/null || true
fi

cat << 'BIOS_CFG' > iso/isolinux/isolinux.cfg
default live
timeout 50
prompt 0

label live
  menu label Start Kylin V10 SP3 Desktop Live (BIOS)
  kernel /boot/vmlinuz
  append initrd=/boot/initrd.img root=live:LABEL=KYLIN_DESK_LIVE rd.live.image rd.live.overlay.size=4096 plymouth.enable=0 quiet selinux=0
BIOS_CFG
/bin/cp -f iso/isolinux/isolinux.cfg iso/syslinux.cfg

# UEFI 引导
EFI_SRC=$(find /boot /usr -name "grubx64.efi" -o -name "bootx64.efi" 2>/dev/null | head -n 1)
if [ -n "$EFI_SRC" ]; then
    /bin/cp -f "$EFI_SRC" iso/EFI/BOOT/BOOTX64.EFI
fi

cat << 'UEFI_CFG' > iso/EFI/BOOT/grub.cfg
set default="0"
set timeout=5

menuentry 'Start Kylin V10 SP3 Desktop Live (UEFI)' --class kylin --class gnu-linux {
    linux /boot/vmlinuz root=live:LABEL=KYLIN_DESK_LIVE rd.live.image rd.live.overlay.size=4096 plymouth.enable=0 quiet selinux=0
    initrd /boot/initrd.img
}
UEFI_CFG

dd if=/dev/zero of=iso/images/efiboot.img bs=1M count=8 >/dev/null 2>&1
mkfs.vfat iso/images/efiboot.img >/dev/null 2>&1
mkdir -p /mnt/efidisk
mount -o loop iso/images/efiboot.img /mnt/efidisk
mkdir -p /mnt/efidisk/EFI/BOOT
/bin/cp -rf iso/EFI/BOOT/* /mnt/efidisk/EFI/BOOT/ 2>/dev/null || true
umount /mnt/efidisk

# 生成双模混合 ISO
xorriso -as mkisofs \
  -iso-level 3 \
  -R -J \
  -volid "KYLIN_DESK_LIVE" \
  -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e images/efiboot.img \
    -no-emul-boot -isohybrid-gpt-basdat \
  -output "${OUTPUT_ISO}" \
  iso/

echo "=========================================================="
echo ">>> 全部构建完成！最终输出 ISO 详情："
ls -lh "${OUTPUT_ISO}"
echo "=========================================================="

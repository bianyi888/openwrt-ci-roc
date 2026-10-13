#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEVICE_CONFIG_FILE="${1:-${CONFIG_FILE:-}}"
GENERAL_CONFIG_FILE="${2:-${GENERAL_CONFIG_FILE:-configs/General.config}}"
GIT_CLONE_RETRY_COUNT="${GIT_CLONE_RETRY_COUNT:-3}"
THIRD_PARTY_SOURCES_FILE="${THIRD_PARTY_SOURCES_FILE:-$PWD/third-party-sources.txt}"

case "$GIT_CLONE_RETRY_COUNT" in
  '' | *[!0-9]* | 0)
    echo "Error: GIT_CLONE_RETRY_COUNT must be a positive integer" >&2
    exit 1
    ;;
esac

resolve_config_file() {
  local config_file="$1"

  if [ -f "$config_file" ]; then
    printf '%s\n' "$config_file"
  elif [ -f "$WORKSPACE/$config_file" ]; then
    printf '%s\n' "$WORKSPACE/$config_file"
  else
    echo "Error: configuration file was not found: $config_file" >&2
    return 1
  fi
}

CONFIG_FILES=()
if [ -n "$DEVICE_CONFIG_FILE" ]; then
  CONFIG_FILES+=("$(resolve_config_file "$DEVICE_CONFIG_FILE")")
elif [ -f .config ]; then
  # Keep direct invocations compatible with an existing OpenWrt .config.
  CONFIG_FILES+=("$PWD/.config")
else
  echo "Error: pass the device config as the first argument or CONFIG_FILE" >&2
  exit 1
fi
CONFIG_FILES+=("$(resolve_config_file "$GENERAL_CONFIG_FILE")")

config_symbol_enabled() {
  local symbol="$1"

  awk -v symbol="$symbol" '
    { sub(/\r$/, "") }
    $0 == symbol "=y" || $0 == symbol "=m" { enabled = 1; next }
    $0 == symbol "=n" || $0 == "# " symbol " is not set" { enabled = 0 }
    END { exit(enabled ? 0 : 1) }
  ' "${CONFIG_FILES[@]}"
}

target_device_package_enabled() {
  local package_name="$1"

  awk -v package_name="$package_name" '
    { sub(/\r$/, "") }
    /^CONFIG_TARGET_DEVICE_PACKAGES_[^=]+="/ {
      packages = $0
      sub(/^[^"]*"/, "", packages)
      sub(/"$/, "", packages)
      count = split(packages, values, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (values[i] == package_name) {
          found = 1
        }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "${CONFIG_FILES[@]}"
}

package_enabled() {
  local package_name

  for package_name in "$@"; do
    if config_symbol_enabled "CONFIG_PACKAGE_$package_name" || target_device_package_enabled "$package_name"; then
      return 0
    fi
  done

  return 1
}

clone_with_retry() {
  local target_dir="$1"
  local attempt
  shift

  for ((attempt = 1; attempt <= GIT_CLONE_RETRY_COUNT; attempt++)); do
    rm -rf "$target_dir"
    if git clone "$@" "$target_dir"; then
      return 0
    fi

    if [ "$attempt" -lt "$GIT_CLONE_RETRY_COUNT" ]; then
      echo "Git clone failed; retrying ($((attempt + 1))/$GIT_CLONE_RETRY_COUNT): ${*: -1}" >&2
      sleep $((attempt * 2))
    fi
  done

  echo "Error: git clone failed after $GIT_CLONE_RETRY_COUNT attempts: ${*: -1}" >&2
  return 1
}

record_git_revision() {
  local repo_url="$1"
  local branch="$2"
  local checkout_dir="$3"
  local commit
  local revision

  commit="$(git -C "$checkout_dir" rev-parse HEAD)"
  printf -v revision '%s\t%s\t%s' "$repo_url" "$branch" "$commit"
  grep -Fqx -- "$revision" "$THIRD_PARTY_SOURCES_FILE" || printf '%s\n' "$revision" >> "$THIRD_PARTY_SOURCES_FILE"
}

clone_repository() {
  local repo_url="$1"
  local branch="$2"
  local target_dir="$3"

  clone_with_retry "$target_dir" \
    --depth=1 \
    --no-tags \
    --branch "$branch" \
    --single-branch \
    "$repo_url"
  record_git_revision "$repo_url" "$branch" "$target_dir"
}

mkdir -p "$(dirname "$THIRD_PARTY_SOURCES_FILE")"
printf 'Repository\tBranch\tCommit\n' > "$THIRD_PARTY_SOURCES_FILE"

# 修改默认IP & 固件名称 & 编译署名和时间
sed -i 's/192.168.1.1/192.168.5.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='Roc'/g" package/base-files/files/bin/config_generate
luci_system_js="feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
firmware_version_anchor="_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),"
grep -Fq "$firmware_version_anchor" "$luci_system_js" || { echo "Error: LuCI firmware version anchor was not found in $luci_system_js" >&2; exit 1; }
sed -i "s#_('Firmware Version'), (L\.isObject(boardinfo\.release) ? boardinfo\.release\.description + ' / ' : '') + (luciversion || ''),# \
            _('Firmware Version'),\n \
            E('span', {}, [\n \
                (L.isObject(boardinfo.release)\n \
                ? boardinfo.release.description + ' / '\n \
                : '') + (luciversion || '') + ' / ',\n \
            E('a', {\n \
                href: 'https://github.com/laipeng668/openwrt-ci-roc/releases',\n \
                target: '_blank',\n \
                rel: 'noopener noreferrer'\n \
                }, [ 'Built by Roc $(date "+%Y-%m-%d %H:%M:%S")' ])\n \
            ]),#" "$luci_system_js"

# 调整NSS驱动q6_region内存区域预留大小（ipq6018.dtsi默认预留85MB，ipq6018-512m.dtsi默认预留55MB，带WiFi必须至少预留54MB，以下分别是改成预留16MB、32MB、64MB和96MB）
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x01000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x02000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x06000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi

# 调节IPQ60XX的1.5GHz频率电压(从0.9375V提高到0.95V，过低可能导致不稳定，过高可能增加功耗和发热，具体数值需要根据实际情况调整)
# sed -i 's/opp-microvolt = <937500>;/opp-microvolt = <950000>;/' target/linux/qualcommax/patches-6.12/0038-v6.16-arm64-dts-qcom-ipq6018-add-1.5GHz-CPU-Frequency.patch

# Git稀疏克隆，只克隆指定目录到本地
git_sparse_clone() {
  local branch="$1"
  local repourl="$2"
  local repodir
  local sparse_path
  shift 2

  repodir="$(basename "${repourl%.git}")"
  clone_with_retry "$repodir" \
    --depth=1 \
    --no-tags \
    --branch "$branch" \
    --single-branch \
    --filter=blob:none \
    --sparse \
    "$repourl"
  (
    cd "$repodir"
    git sparse-checkout set "$@"
  )
  record_git_revision "$repourl" "$branch" "$repodir"

  for sparse_path in "$@"; do
    rm -rf "package/$(basename "$sparse_path")"
    mv "$repodir/$sparse_path" package/
  done
  rm -rf "$repodir"
}

# Aria2 & nginx & Go & DDNS & frp & UPnP & Wol
rm -rf feeds/packages/lang/golang
git_sparse_clone master https://github.com/laipeng668/packages lang/golang
mv package/golang feeds/packages/lang/golang

if package_enabled luci-app-aria2 aria2; then
  rm -rf feeds/packages/net/aria2
  git_sparse_clone aria2 https://github.com/laipeng668/packages net/aria2
  mv package/aria2 feeds/packages/net/aria2
fi
if package_enabled ariang; then
  rm -rf feeds/packages/net/ariang
  git_sparse_clone ariang https://github.com/laipeng668/packages net/ariang
  mv package/ariang feeds/packages/net/ariang
fi

if package_enabled nginx nginx-full nginx-ssl luci-app-nginx; then
  rm -rf feeds/packages/net/nginx
  git_sparse_clone nginx https://github.com/laipeng668/packages net/nginx
  mv package/nginx feeds/packages/net/nginx
fi

if package_enabled luci-app-ddns ddns-scripts ddns-scripts-cloudflare; then
  rm -rf feeds/packages/net/ddns-scripts
  git_sparse_clone master https://github.com/laipeng668/packages net/ddns-scripts
  mv package/ddns-scripts feeds/packages/net/ddns-scripts
fi
if package_enabled luci-app-ddns; then
  rm -rf feeds/luci/applications/luci-app-ddns
  git_sparse_clone master https://github.com/laipeng668/luci applications/luci-app-ddns
  mv package/luci-app-ddns feeds/luci/applications/luci-app-ddns
fi

if package_enabled frp frpc frps luci-app-frpc luci-app-frps; then
  rm -rf \
    feeds/packages/net/frp
  git_sparse_clone frp-binary https://github.com/laipeng668/packages net/frp
  mv package/frp feeds/packages/net/frp
fi

frp_luci_paths=()
if package_enabled luci-app-frpc; then
  rm -rf feeds/luci/applications/luci-app-frpc
  frp_luci_paths+=(applications/luci-app-frpc)
fi
if package_enabled luci-app-frps; then
  rm -rf feeds/luci/applications/luci-app-frps
  frp_luci_paths+=(applications/luci-app-frps)
fi
if [ "${#frp_luci_paths[@]}" -gt 0 ]; then
  git_sparse_clone frp https://github.com/laipeng668/luci "${frp_luci_paths[@]}"
  for frp_luci_path in "${frp_luci_paths[@]}"; do
    mv "package/$(basename "$frp_luci_path")" "feeds/luci/$frp_luci_path"
    sed -i '/^LUCI_EXTRA_DEPENDS:=/d' "feeds/luci/$frp_luci_path/Makefile"
  done
fi

if package_enabled luci-app-upnp miniupnpd; then
  rm -rf feeds/packages/net/miniupnpd
  git_sparse_clone master https://github.com/immortalwrt/packages net/miniupnpd
  mv package/miniupnpd feeds/packages/net/miniupnpd
fi
if package_enabled luci-app-upnp; then
  rm -rf feeds/luci/applications/luci-app-upnp
  git_sparse_clone master https://github.com/immortalwrt/luci applications/luci-app-upnp
  mv package/luci-app-upnp feeds/luci/applications/luci-app-upnp
fi

if package_enabled luci-app-wol; then
  rm -rf feeds/luci/applications/luci-app-wol
  git_sparse_clone master https://github.com/immortalwrt/luci applications/luci-app-wol
  mv package/luci-app-wol feeds/luci/applications/luci-app-wol
fi

# Themes and standalone applications. A config application pulls in its theme as a dependency.
if package_enabled luci-theme-argon luci-app-argon-config; then
  rm -rf feeds/luci/themes/luci-theme-argon
  clone_repository https://github.com/jerrykuku/luci-theme-argon master feeds/luci/themes/luci-theme-argon
fi
if package_enabled luci-app-argon-config; then
  rm -rf feeds/luci/applications/luci-app-argon-config
  clone_repository https://github.com/jerrykuku/luci-app-argon-config master feeds/luci/applications/luci-app-argon-config
fi

if package_enabled luci-theme-aurora luci-app-aurora-config; then
  rm -rf feeds/luci/themes/luci-theme-aurora
  clone_repository https://github.com/eamonxg/luci-theme-aurora master feeds/luci/themes/luci-theme-aurora
fi
if package_enabled luci-app-aurora-config; then
  rm -rf feeds/luci/applications/luci-app-aurora-config
  clone_repository https://github.com/eamonxg/luci-app-aurora-config master feeds/luci/applications/luci-app-aurora-config
fi

if package_enabled luci-app-openlist2 openlist2; then
  clone_repository https://github.com/laipeng668/luci-app-openlist2 main package/openlist2
fi

if package_enabled luci-app-lucky lucky; then
  clone_repository https://github.com/gdy666/luci-app-lucky main package/luci-app-lucky
fi

if package_enabled luci-app-daede daed; then
  clone_repository https://github.com/kenzok8/openwrt-daede main package/openwrt-daede
  # daed 需要 BPF 工具链（clang），否则 bpf-headers 编译失败（/invalid/clang）
  DAED_MAKEFILE="package/openwrt-daede/daed/Makefile"
  if [ -f "$DAED_MAKEFILE" ]; then
    sed -i 's|+DAED_USE_VMLINUX_BTF:vmlinux-btf$|+DAED_USE_VMLINUX_BTF:vmlinux-btf \\\n\t$(BPF_DEPENDS)|' "$DAED_MAKEFILE"
    grep -qF '$(BPF_DEPENDS)' "$DAED_MAKEFILE" && echo "daed Makefile patched: BPF_DEPENDS added" || { echo "ERROR: failed to patch daed Makefile"; exit 1; }
  fi
fi

if package_enabled luci-app-honk honk; then
  # honk 从 kenzok8/small 稀疏检出（只拿 honk 和 luci-app-honk 目录）
  rm -rf package/honk-src-tmp
  clone_with_retry "package/honk-src-tmp" \
    --depth=1 \
    --no-tags \
    --branch master \
    --single-branch \
    --filter=blob:none \
    --sparse \
    https://github.com/kenzok8/small
  (
    cd package/honk-src-tmp
    git sparse-checkout set honk luci-app-honk
  )
  rm -rf package/honk package/luci-app-honk
  mv package/honk-src-tmp/honk package/honk
  mv package/honk-src-tmp/luci-app-honk package/luci-app-honk
  rm -rf package/honk-src-tmp
  # honk: 去掉对 vmlinux-btf 包的依赖（用内核内置 BTF，内核已开 CONFIG_KERNEL_DEBUG_INFO_BTF）
  # 否则缺 vmlinux-btf 包会导致 package/install 阶段报错
  HONK_MAKEFILE="package/honk/Makefile"
  if [ -f "$HONK_MAKEFILE" ]; then
    # 把 DEPENDS 中的条件依赖行换成注释（直接删行会留下悬空续行符 \ 导致 make 报 missing 'endef'）
    sed -i 's|^[[:space:]]*+HONK_USE_VMLINUX_BTF:vmlinux-btf$|    # vmlinux-btf dep removed: kernel BTF is built-in|' "$HONK_MAKEFILE"
    grep -qF '# vmlinux-btf dep removed' "$HONK_MAKEFILE" || { echo "ERROR: honk Makefile patch did not apply"; exit 1; }
    grep -qE '^[[:space:]]*\+[^#]*vmlinux-btf' "$HONK_MAKEFILE" && { echo "ERROR: vmlinux-btf dependency still present"; exit 1; }
    echo "honk Makefile patched: vmlinux-btf dependency removed"
  fi
  echo "honk packages prepared from kenzok8/small"
fi

# 内核 BTF 连锁钉死：CONFIG_KERNEL_DEBUG_INFO_BTF=y 会经
# KERNEL_BPF_EVENTS->KERNEL_KPROBES->KERNEL_PERF_EVENTS 把内核
# "Performance monitor support" 菜单及 BTF 子选项变为可见，其中部分符号
# （ARM64_BRBE、MODULE_ALLOW_BTF_MISMATCH 等）在 defconfig 里无值，
# 内核 syncconfig 会交互提问，非交互构建直接失败（run 38406475646/38426656361）。
# 注意：CONFIG_KERNEL_<SYM>=n 写进 General.Honk.config 对这类符号无效——
# 若 <SYM> 未在 OpenWrt 的 config/Config-kernel.in 里定义，顶层 make defconfig
# 会把它当未知符号静默丢弃，根本到不了内核 .config。必须把内核原生符号
# 直接钉进 target 内核配置（kconfig.pl 在内核编译时合并读取）。
if config_symbol_enabled "CONFIG_KERNEL_DEBUG_INFO_BTF"; then
  IPQ60XX_CONFIG_DEFAULT="target/linux/qualcommax/ipq60xx/config-default"
  if [ -f "$IPQ60XX_CONFIG_DEFAULT" ] && ! grep -q "BTF/PMU symbols pinned" "$IPQ60XX_CONFIG_DEFAULT"; then
    {
      echo ""
      echo "# BTF/PMU symbols pinned for non-interactive kernel syncconfig (Roc-script.sh)"
      echo "# CONFIG_ARM_CCI_PMU is not set"
      echo "# CONFIG_ARM_CCN is not set"
      echo "# CONFIG_ARM_CMN is not set"
      echo "# CONFIG_ARM_NI is not set"
      echo "CONFIG_ARM_PMU=y"
      echo "# CONFIG_ARM_SMMU_V3_PMU is not set"
      echo "# CONFIG_ARM_DSU_PMU is not set"
      echo "# CONFIG_ARM_SPE_PMU is not set"
      echo "# CONFIG_ARM64_BRBE is not set"
      echo "CONFIG_DEBUG_INFO_BTF_MODULES=y"
      echo "# CONFIG_MODULE_ALLOW_BTF_MISMATCH is not set"
    } >> "$IPQ60XX_CONFIG_DEFAULT"
    echo "kernel config pinned: BTF/PMU symbols appended to $IPQ60XX_CONFIG_DEFAULT"
  fi
fi

# 亚瑟 jdcloud_re-ss-01：honk 需要内核 BTF，FIT 内核约 7.2MB 超 6M 上限
# （check-size 会删掉超限镜像，导致 sysupgrade 生成失败；2026-10-09 同故障）
# 用户 uboot 为 chenxin527 12m 自适应版（自动识别内核大小），放大到 8M 安全
IPQ60XX_IMAGE_MK="target/linux/qualcommax/image/ipq60xx.mk"
sed -i '/^define Device\/jdcloud_re-ss-01$/,/^endef$/ s/^\tKERNEL_SIZE := 6144k$/\tKERNEL_SIZE := 8192k/' "$IPQ60XX_IMAGE_MK"
grep -A8 '^define Device/jdcloud_re-ss-01$' "$IPQ60XX_IMAGE_MK" | grep -q 'KERNEL_SIZE := 8192k' \
  || { echo "ERROR: KERNEL_SIZE patch did not apply for jdcloud_re-ss-01"; exit 1; }
echo "kernel size patched: jdcloud_re-ss-01 KERNEL_SIZE 6144k -> 8192k"

if package_enabled luci-app-wechatpush; then
  rm -rf feeds/luci/applications/luci-app-wechatpush
  clone_repository https://github.com/tty228/luci-app-wechatpush master package/luci-app-wechatpush
fi

if package_enabled luci-app-oaf open-app-filter; then
  rm -rf feeds/luci/applications/luci-app-appfilter feeds/packages/net/open-app-filter
  clone_repository https://github.com/destan19/OpenAppFilter.git master package/OpenAppFilter
fi

if package_enabled luci-app-gecoosac gecoosac; then
  clone_repository https://github.com/laipeng668/luci-app-gecoosac main package/luci-app-gecoosac
fi

if package_enabled luci-app-athena-led luci-i18n-athena-led-zh-cn; then
  clone_repository https://github.com/NONGFAH/luci-app-athena-led main package/luci-app-athena-led
  chmod +x package/luci-app-athena-led/root/etc/init.d/athena_led package/luci-app-athena-led/root/usr/sbin/athena-led
fi

### PassWall & OpenClash ###

if package_enabled luci-app-passwall luci-app-passwall2; then
  # 移除 OpenWrt Feeds 自带的核心库
  rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
  clone_repository https://github.com/Openwrt-Passwall/openwrt-passwall-packages main package/passwall-packages
fi

if package_enabled luci-app-passwall; then
  rm -rf feeds/luci/applications/luci-app-passwall
  clone_repository https://github.com/Openwrt-Passwall/openwrt-passwall main package/luci-app-passwall
fi

if package_enabled luci-app-passwall2; then
  rm -rf feeds/luci/applications/luci-app-passwall2
  clone_repository https://github.com/Openwrt-Passwall/openwrt-passwall2 main package/luci-app-passwall2
fi

if package_enabled luci-app-openclash; then
  rm -rf feeds/luci/applications/luci-app-openclash
  clone_repository https://github.com/vernesong/OpenClash master package/luci-app-openclash
fi

# 清理 PassWall 的 chnlist 规则文件
# echo "baidu.com"  > package/luci-app-passwall/luci-app-passwall/root/usr/share/passwall/rules/chnlist

./scripts/feeds update -i -a
./scripts/feeds install -a

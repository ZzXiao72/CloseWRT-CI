#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#移除luci-app-attendedsysupgrade
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "/attendedsysupgrade/d" {} +
#修改默认主题
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" {} +
#修改immortalwrt.lan关联IP
find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" -exec sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" {} +
#添加编译日期标识
find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" -exec sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" {} +

MTWIFI_SH="./package/mtk/applications/mtwifi-cfg/files/mtwifi.sh"
if [ -f "$MTWIFI_SH" ]; then
	#修改默认名称密码
	sed -i -E "s/ImmortalWrt/$WRT_SSID/g; s/(.*)encryption=none/\1encryption=psk2+ccmp\n\1key=$WRT_WORD/" $MTWIFI_SH
fi

MTWIFI_UC="./package/mtk/applications/mtwifi-cfg-ucode/files/lib/wifi/mtwifi.uc"
if [ -f "$MTWIFI_UC" ]; then
	#修改默认名称密码
	sed -i "s/ImmortalWrt/$WRT_SSID/g; s/\"none\"/\"psk2+ccmp\", \"key\": \"$WRT_WORD\"/" $MTWIFI_UC
	# 使用对应的用户态组件，避免与旧 Lua 组件同时选中。
	printf '# CONFIG_PACKAGE_mtwifi-cfg is not set\n# CONFIG_PACKAGE_iwinfo is not set\nCONFIG_PACKAGE_mtwifi-cfg-ucode=y\n' >> .config
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#首启网络兜底：config_generate 未生成 lan 时，写入可用的 LAN + DHCP 配置
mkdir -p ./package/base-files/files/etc/uci-defaults
cat > ./package/base-files/files/etc/uci-defaults/98-cwrt-net <<'CWRTEOL'
#!/bin/sh

[ -f /etc/config/network ] || touch /etc/config/network

if ! uci -q get network.lan >/dev/null; then
	uci -q batch <<-EOF
		set network.lan='interface'
		set network.lan.device='br-lan'
		set network.lan.proto='static'
		set network.lan.ipaddr='192.168.0.1'
		set network.lan.netmask='255.255.255.0'
		set network.lan.ip6assign='60'
	EOF

	uci -q batch <<-EOF
		set network.cwrt_lan_dev='device'
		set network.cwrt_lan_dev.name='br-lan'
		set network.cwrt_lan_dev.type='bridge'
	EOF

	for dev in lan1 lan2 lan3 lan4; do
		[ -d "/sys/class/net/$dev" ] && uci -q add_list network.cwrt_lan_dev.ports="$dev"
	done

	[ -d /sys/class/net/eth1 ] && {
		uci -q batch <<-EOF
			set network.wan='interface'
			set network.wan.device='eth1'
			set network.wan.proto='dhcp'
		EOF
	}
fi

uci -q get dhcp.lan >/dev/null || {
	uci -q batch <<-EOF
		set dhcp.lan='dhcp'
		set dhcp.lan.interface='lan'
		set dhcp.lan.start='100'
		set dhcp.lan.limit='150'
		set dhcp.lan.leasetime='12h'
	EOF
}

uci -q commit network
uci -q commit dhcp

exit 0
CWRTEOL
chmod +x ./package/base-files/files/etc/uci-defaults/98-cwrt-net

#引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

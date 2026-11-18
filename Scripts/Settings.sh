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

	#默认无线参数：2.4G 20MHz 且不强制40MHz、5G 自动信道 160MHz、关闭 802.11k、关闭 U-APSD
	sed -i -e 's/htmode="HE40"/htmode="HE20"/' -e 's/htbsscoex="1"/htbsscoex="0"/' -e 's/channel="36"/channel="auto"/' "$MTWIFI_SH"
	sed -i 's|set wireless.${dev}.noscan=${htbsscoex}|set wireless.${dev}.noscan=${htbsscoex}\n\t\t\t\t\tset wireless.${dev}.ieee80211k=0\n\t\t\t\t\tset wireless.${dev}.uapsd=0|' "$MTWIFI_SH"
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
#默认不生成 WAN6 接口
sed -i 's|\tfor key in $keys; do generate_network $key $bridge_name; done|\tfor key in $keys; do generate_network $key $bridge_name; done\n\tuci -q delete network.wan6|' $CFG_FILE

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

#首启默认项：UPnP 开启、HNAT PPE 数量 1、删除 WAN6、纠正无线默认值
cat > ./package/base-files/files/etc/uci-defaults/zz-cwrt-defaults <<'CWRTEOL'
#!/bin/sh

# UPnP 默认开启
uci -q set upnpd.config.enabled='1'
uci -q set upnpd.config.enable_upnp='1'
uci -q commit upnpd 2>/dev/null

# HNAT PPE 数量
uci -q set turboacc.config.fastpath_mh_eth_hnat_ppenum='1'
uci -q commit turboacc 2>/dev/null

# 删除 WAN6 接口（用不上），并关闭 WAN 上的 IPv6
uci -q delete network.wan6 2>/dev/null
[ -n "$(uci -q get network.wan)" ] && uci -q set network.wan.ipv6='0'
uci -q commit network 2>/dev/null

# WAN 若是没填账号的 PPPoE（出厂占位值），恢复成 DHCP
if [ "$(uci -q get network.wan.proto)" = "pppoe" ]; then
	WANUSER="$(uci -q get network.wan.username)"
	if [ "$WANUSER" = "username" ] || [ -z "$WANUSER" ]; then
		uci -q set network.wan.proto='dhcp'
		uci -q delete network.wan.username
		uci -q delete network.wan.password
		uci -q commit network 2>/dev/null
	fi
fi

# 无线默认项：即使旧配置被保留，也强制纠正为 20MHz/160MHz、关 802.11k、关 U-APSD
for sec in $(uci -q show wireless 2>/dev/null | sed -n 's/^wireless\.\([^=]*\)=wifi-device$/\1/p'); do
	[ "$(uci -q get wireless.$sec.type)" = "mtwifi" ] || continue
	uci -q set wireless.$sec.ieee80211k='0'
	uci -q set wireless.$sec.uapsd='0'
	uci -q set wireless.$sec.noscan='0'
	case "$(uci -q get wireless.$sec.band)" in
		2g)
			uci -q set wireless.$sec.htmode='HE20'
			uci -q set wireless.$sec.channel='auto'
		;;
		5g)
			uci -q set wireless.$sec.htmode='HE160'
			uci -q set wireless.$sec.channel='auto'
		;;
	esac
done
uci -q commit wireless 2>/dev/null

exit 0
CWRTEOL
chmod +x ./package/base-files/files/etc/uci-defaults/zz-cwrt-defaults

#HNAT 模块按 1 个 PPE 加载
mkdir -p ./package/base-files/files/etc/modules.d
echo 'mtkhnat ppe_cnt=1' > ./package/base-files/files/etc/modules.d/19-cwrt-hnat

#默认计划任务：每周三、周日 7:00 重启（周日=0，周三=3）
mkdir -p ./package/base-files/files/etc/crontabs
cat > ./package/base-files/files/etc/crontabs/root <<'CWRTEOL'
0 7 * * 0,3 /sbin/reboot
CWRTEOL

#引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

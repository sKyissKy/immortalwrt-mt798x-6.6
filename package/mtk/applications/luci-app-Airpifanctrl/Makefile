# by Manper 20250520

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-Airpifanctrl
PKG_VERSION:=2.0
PKG_RELEASE:=12

LUCI_TITLE:=LuCI JS Support for Airpi PWM Fan Control
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-base +rpcd +ucode +ucode-mod-fs +ucode-mod-ubus

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature

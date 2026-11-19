# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=mtk-npu-sqm
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only
PKG_ARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/mtk-npu-sqm
  SECTION:=net
  CATEGORY:=Network
  TITLE:=MediaTek NETSYS v3 QDMA Hardware SQM-QoS controller
  DEPENDS:=+kmod-mediatek_hnat +kmod-sched-cake +kmod-sched-core +tc
endef

define Package/mtk-npu-sqm/description
  Hardware-offloaded SQM/HQoS controller for MediaTek MT7987/MT7988 NETSYS v3
  QDMA schedulers (qdma_sch2/qdma_sch3 + txq16..31/txq48..63) with automatic
  hybrid CAKE uplink support for IS_EXT 5G cellular WAN (e.g. wwan0_1).
endef

define Package/mtk-npu-sqm/conffiles
/etc/config/mtk_npu_sqm
endef

define Build/Compile
endef

define Package/mtk-npu-sqm/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/mtk_npu_sqm.config $(1)/etc/config/mtk_npu_sqm
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/mtk-npu-sqm $(1)/usr/sbin/mtk-npu-sqm
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/mtk_npu_sqm.init $(1)/etc/init.d/mtk_npu_sqm
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_DATA) ./files/95-mtk-npu-sqm.hotplug $(1)/etc/hotplug.d/iface/95-mtk-npu-sqm
endef

$(eval $(call BuildPackage,mtk-npu-sqm))

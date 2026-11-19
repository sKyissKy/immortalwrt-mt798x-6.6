/* Copyright (C) 2026 ImmortalWrt.org */

'use strict';
'require form';
'require poll';
'require rpc';
'require ui';
'require view';

var callGetStatus = rpc.declare({
	object: 'luci.mtk_npu_sqm',
	method: 'getStatus',
	expect: { '': {} }
});

var callApply = rpc.declare({
	object: 'luci.mtk_npu_sqm',
	method: 'apply',
	expect: { '': {} }
});

function dismissBannerElement(msg) {
	if (!msg)
		return;
	msg.classList.add('fade-out');
	msg.classList.remove('fade-in');
	window.setTimeout(function() {
		if (msg.parentNode)
			msg.parentNode.removeChild(msg);
	}, 180);
}

function showBanner(title, children, timeoutMs, cssClass) {
	var msg = (timeoutMs && timeoutMs > 0)
		? ui.addTimeLimitedNotification(title, children, timeoutMs, cssClass)
		: ui.addNotification(title, children, cssClass);
	if (msg) {
		msg.querySelectorAll('.btn').forEach(function(btn) {
			btn.addEventListener('click', function() {
				dismissBannerElement(msg);
			});
		});
	}
	return msg;
}

function fmtSch(sch) {
	if (!sch)
		return '--';
	return (sch.enabled ? _('Enabled') : _('Disabled')) +
		' (' + (sch.alg || 'WRR') + ', ' + (sch.rate || 0) + ' kbit/s)';
}

function fmtCounters(pkt, drop) {
	return _('Packets') + ': ' + (pkt != null ? pkt : 0) +
		' / ' + _('Drops') + ': ' + (drop != null ? drop : 0);
}

function updateStatusDOM(st) {
	if (!st || st.error)
		return;

	var elState = document.getElementById('npu-sqm-state');
	var elMode = document.getElementById('npu-sqm-mode');
	var elWan = document.getElementById('npu-sqm-wan');
	var elHnat = document.getElementById('npu-sqm-hnat');
	var elDl = document.getElementById('npu-sqm-dl');
	var elUl = document.getElementById('npu-sqm-ul');
	var elCake = document.getElementById('npu-sqm-cake');

	if (elState) {
		if (st.conflict)
			elState.textContent = _('Blocked (EQoS / mtkhqos active)');
		else if (st.active && st.sqm_toggle)
			elState.textContent = _('Active (Hardware PPE + QDMA)');
		else if (st.active)
			elState.textContent = _('Active (CAKE Uplink Only)');
		else
			elState.textContent = _('Stopped');
	}

	if (elMode) {
		elMode.textContent = (st.wan_mode === 'hybrid_ext')
			? _('Hybrid (QDMA Hardware Downlink + CAKE Uplink)')
			: _('Full Hardware NPU QDMA (Bidirectional)');
	}

	if (elWan)
		elWan.textContent = st.wan_dev || '--';

	if (elHnat) {
		elHnat.textContent =
			'hook=' + (st.hook_toggle ? 1 : 0) +
			', sqm=' + (st.sqm_toggle ? 1 : 0) +
			', qos=' + (st.qos_toggle != null ? st.qos_toggle : 0);
	}

	var stats = st.stats || {};
	if (elDl) {
		elDl.textContent = fmtSch(st.sch3) +
			' | ' + _('Priority Q48') + ' [' + fmtCounters(stats.dl_prio_pkt, stats.dl_prio_drop) + ']' +
			' | ' + _('Flow Q49-63') + ' [' + fmtCounters(stats.dl_bulk_pkt, stats.dl_bulk_drop) + ']';
	}

	if (elUl) {
		elUl.textContent = fmtSch(st.sch2) +
			' | ' + _('Priority Q16') + ' [' + fmtCounters(stats.ul_prio_pkt, stats.ul_prio_drop) + ']' +
			' | ' + _('Flow Q17-31') + ' [' + fmtCounters(stats.ul_bulk_pkt, stats.ul_bulk_drop) + ']';
	}

	if (elCake)
		elCake.textContent = (st.cake && st.cake.length > 0) ? st.cake : _('None');
}

return view.extend({
	load: function() {
		return callGetStatus();
	},

	render: function(status) {
		status = status || {};

		var m = new form.Map(
			'mtk_npu_sqm',
			_('MediaTek NPU Hardware SQM QoS'),
			_('Configure NETSYS v3 QDMA 16-queue fair/priority hardware SQM scheduling and hybrid CAKE uplink shaping for 5G EXT interfaces.')
		);
		this.map = m;

		var s = m.section(form.NamedSection, '__status', '_status', _('Realtime Status'));
		s.render = function() {
			var statusTable = E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, _('Engine State')),
					E('td', { 'class': 'td left', 'id': 'npu-sqm-state' }, '--')
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, _('Offload Mode')),
					E('td', { 'class': 'td left', 'id': 'npu-sqm-mode' }, '--')
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, _('Bound WAN Interface')),
					E('td', { 'class': 'td left', 'id': 'npu-sqm-wan' }, '--')
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, _('HNAT Kernel Flags')),
					E('td', { 'class': 'td left', 'id': 'npu-sqm-hnat' }, '--')
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, _('Downlink QDMA (Scheduler 3)')),
					E('td', { 'class': 'td left', 'id': 'npu-sqm-dl' }, '--')
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, _('Uplink QDMA (Scheduler 2)')),
					E('td', { 'class': 'td left', 'id': 'npu-sqm-ul' }, '--')
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, _('CAKE Uplink Qdisc')),
					E('td', { 'class': 'td left', 'id': 'npu-sqm-cake' }, '--')
				])
			]);

			poll.add(function() {
				return callGetStatus().then(function(res) {
					updateStatusDOM(res);
				});
			}, 5);

			var wrap = E('fieldset', { 'class': 'cbi-section' }, [
				E('legend', {}, _('Realtime Status')),
				statusTable
			]);
			window.setTimeout(function() { updateStatusDOM(status); }, 0);
			return wrap;
		};

		s = m.section(form.NamedSection, 'global', 'sqm', _('SQM Policy Settings'));

		var o = s.option(form.Flag, 'enabled', _('Enable NPU SQM QoS'));
		o.rmempty = false;

		o = s.option(form.Value, 'wan_ifname', _('WAN Interface'));
		o.value('auto', _('Auto Detect (5G wwan / Ethernet WAN)'));
		o.value('wwan0_1', 'wwan0_1 (5G QMI RM520F)');
		o.value('eth1', 'eth1 (Ethernet WAN)');
		o.default = 'auto';
		o.rmempty = false;

		o = s.option(form.Value, 'download', _('Download Bandwidth (kbit/s)'));
		o.datatype = 'range(0,10000000)';
		o.default = '0';
		o.rmempty = false;
		o.description = _('Set 0 to disable downlink shaping. Recommended: 85-95% of measured download speed.');

		o = s.option(form.Value, 'upload', _('Upload Bandwidth (kbit/s)'));
		o.datatype = 'range(0,10000000)';
		o.default = '0';
		o.rmempty = false;
		o.description = _('Set 0 to disable uplink shaping. On 5G wwan interfaces, CAKE runs on egress; on Ethernet WAN, QDMA Scheduler 2 handles uplink in hardware.');

		o = s.option(form.ListValue, 'scheduler', _('Hardware Queue Scheduler'));
		o.value('wrr', _('WRR (Weighted Round Robin)'));
		o.value('sp', _('SP (Strict Priority)'));
		o.default = 'wrr';
		o.rmempty = false;

		o = s.option(form.Value, 'prio_weight', _('Priority Queue Weight (1 - 15)'));
		o.datatype = 'range(1,15)';
		o.default = '15';
		o.rmempty = false;
		o.description = _('Weight applied to hardware priority queues (Q16/Q48: small TCP ACKs, SYN/FIN/RST, DNS, NTP, EF/CS5-7 DSCP).');

		o = s.option(form.Value, 'bulk_weight', _('Flow-Fair Queue Weight (1 - 15)'));
		o.datatype = 'range(1,15)';
		o.default = '4';
		o.rmempty = false;
		o.description = _('Weight applied per queue across 15 hardware 5-tuple hash queues (Q17-31 UL / Q49-63 DL).');

		o = s.option(form.Value, 'queue_resv', _('Hardware Queue Buffer Reserve (1 - 15)'));
		o.datatype = 'range(1,15)';
		o.default = '2';
		o.rmempty = false;

		o = s.option(form.ListValue, 'cake_diffserv', _('CAKE DiffServ Mode (5G EXT Uplink)'));
		o.value('diffserv4', 'diffserv4');
		o.value('diffserv3', 'diffserv3');
		o.value('diffserv8', 'diffserv8');
		o.value('besteffort', 'besteffort');
		o.default = 'diffserv4';
		o.rmempty = false;

		o = s.option(form.Flag, 'cake_ack_filter', _('Enable CAKE ACK Filter (5G EXT Uplink)'));
		o.default = '1';
		o.rmempty = false;

		return m.render();
	},

	handleSaveApply: function(ev, mode) {
		return this.map.save(null, true).then(function() {
			return callApply().then(function(res) {
				if (res && res.status)
					updateStatusDOM(res.status);
				if (!res || res.code !== 0) {
					var msg = (res && res.output) ? res.output : _('Apply returned non-zero status');
					throw new Error(msg);
				}
				showBanner(null, E('p', _('Configuration has been applied.')), 3500, 'info');
			});
		}).catch(function(err) {
			showBanner(null, E('p', _('Failed to apply configuration: %s').format(err.message || err)), 0, 'error');
		});
	},

	handleSave: null,
	handleReset: null
});

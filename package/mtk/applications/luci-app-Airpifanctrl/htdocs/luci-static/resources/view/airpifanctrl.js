/* Copyright (C) 2026 ImmortalWrt.org */

'use strict';
'require dom';
'require form';
'require poll';
'require rpc';
'require ui';
'require view';

var callGetStatus = rpc.declare({
	object: 'luci.airpifanctrl',
	method: 'getStatus',
	expect: { '': {} }
});

var callApplyConfig = rpc.declare({
	object: 'luci.airpifanctrl',
	method: 'applyConfig',
	params: [ 'mode', 'pwm', 'source' ],
	expect: { '': {} }
});

var MODE_LABELS = {
	'stop': _('Silent Mode'),
	'low': _('Low Speed Mode'),
	'normal': _('Normal Mode'),
	'turbo': _('Turbo Mode'),
	'smart': _('Smart Thermal Mode'),
	'stepless': _('Stepless Mode')
};

var SOURCE_LABELS = {
	'cpu': _('CPU Temperature'),
	'modem': _('5G Modem Temperature')
};

function updateStatusDOM(res) {
	if (!res)
		return;

	var elTemp = document.getElementById('fan-temp-val');
	var elSpeed = document.getElementById('fan-speed-val');
	var elMode = document.getElementById('fan-mode-val');
	var elSrc = document.getElementById('fan-src-val');

	if (elTemp && res.fansttp != null)
		elTemp.textContent = res.fansttp + ' °C';
	if (elSpeed && res.fanspd != null)
		elSpeed.textContent = res.fanspd + ' %';
	if (elMode && res.mode != null)
		elMode.textContent = MODE_LABELS[res.mode] || res.fancts || res.mode;
	if (elSrc && res.temp_source != null)
		elSrc.textContent = SOURCE_LABELS[res.temp_source] || res.fansv || res.temp_source;
}

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

function showBanner(title, children, timeoutMs, ...classes) {
	var msg = (timeoutMs && timeoutMs > 0)
		? ui.addTimeLimitedNotification(title, children, timeoutMs, ...classes)
		: ui.addNotification(title, children, ...classes);
	if (msg) {
		msg.querySelectorAll('.btn').forEach(function(btn) {
			btn.addEventListener('click', function() {
				dismissBannerElement(msg);
			});
		});
	}
	return msg;
}

var activeView = null;
var pollGeneration = 0;

function pollFanStatus() {
	var viewSelf = activeView;
	var generation = pollGeneration;
	if (!viewSelf || viewSelf.applyInProgress)
		return Promise.resolve();

	return callGetStatus().then(function(res) {
		if (!res || res.code !== 0)
			throw new Error((res && res.error) ? res.error : 'Invalid status response');
		if (activeView !== viewSelf || viewSelf.applyInProgress || generation !== pollGeneration)
			return;

		updateStatusDOM(res);

		if (res.lucimsg)
			showBanner(null, E('p', _(res.lucimsg)), 3500, 'info');
	});
}

return view.extend({
	load: function() {
		return callGetStatus();
	},

	render: function(status) {
		status = status || {};
		activeView = this;
		this.initialStatus = status;

		this.formData = {
			cooling_control: {
				mode: status.mode || 'smart',
				stepless_pwm: String(status.stepless_pwm != null ? status.stepless_pwm : 192),
				temp_id: status.temp_source || 'cpu'
			}
		};

		var m = new form.JSONMap(
			this.formData,
			_('Fan Control'),
			_('Configure cooling fan operating mode and temperature sensor source.')
		);
		this.map = m;

		var s = m.section(form.NamedSection, '__status', '_status', _('Realtime Status'));
		s.render = function() {
			var curTemp = (status.fansttp != null) ? (status.fansttp + ' °C') : '--';
			var curSpeed = (status.fanspd != null) ? (status.fanspd + ' %') : '--';
			var curMode = (status.mode && MODE_LABELS[status.mode]) ? MODE_LABELS[status.mode] : (status.fancts || '--');
			var curSrc = (status.temp_source && SOURCE_LABELS[status.temp_source]) ? SOURCE_LABELS[status.temp_source] : (status.fansv || '--');

			var statusTable = E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, _('Current Temperature')),
					E('td', { 'class': 'td left', 'id': 'fan-temp-val' }, curTemp)
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, _('Fan Speed')),
					E('td', { 'class': 'td left', 'id': 'fan-speed-val' }, curSpeed)
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, _('Operating Mode')),
					E('td', { 'class': 'td left', 'id': 'fan-mode-val' }, curMode)
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, _('Temperature Source')),
					E('td', { 'class': 'td left', 'id': 'fan-src-val' }, curSrc)
				])
			]);

			if (status.lucimsg)
				showBanner(null, E('p', _(status.lucimsg)), 3500, 'info');

			poll.add(pollFanStatus, 5);

			return E('fieldset', { 'class': 'cbi-section' }, [
				E('legend', {}, _('Realtime Status')),
				statusTable
			]);
		};

		s = m.section(form.NamedSection, 'cooling_control', 'cooling_control', _('Cooling Policy Settings'));

		var o = s.option(form.ListValue, 'mode', _('Operating Mode'));
		o.value('stop', _('Silent Mode (PWM 64 / 25%)'));
		o.value('low', _('Low Speed Mode (PWM 128 / 50%)'));
		o.value('normal', _('Normal Mode (PWM 192 / 75%)'));
		o.value('turbo', _('Turbo Mode (PWM 255 / 100%)'));
		o.value('smart', _('Smart Thermal Mode (Auto)'));
		o.value('stepless', _('Stepless Custom PWM Mode'));
		o.default = 'smart';
		o.rmempty = false;

		o = s.option(form.Value, 'stepless_pwm', _('Stepless PWM Duty (0 - 255)'));
		o.depends('mode', 'stepless');
		o.datatype = 'range(0,255)';
		o.rmempty = false;
		o.default = '192';
		o.description = _('Set fixed PWM value between 0 (0%) and 255 (100%).');

		o = s.option(form.ListValue, 'temp_id', _('Temperature Sensor Source'));
		o.value('cpu', _('CPU Thermal Zone (thermal_zone0)'));
		o.value('modem', _('5G Modem Chip Temperature (AT+QTEMP / AT^CHIPTEMP)'));
		o.default = 'cpu';
		o.rmempty = false;

		return m.render();
	},

	handleSaveApply: function(ev, mode) {
		var viewSelf = this;
		if (viewSelf.applyInProgress)
			return Promise.resolve();

		viewSelf.applyInProgress = true;
		pollGeneration++;
		poll.remove(pollFanStatus);
		var shouldApply = false;

		return Promise.resolve().then(function() {
			return viewSelf.map.save(null, true);
		}).then(function() {
			var cfg = (viewSelf.formData && viewSelf.formData.cooling_control)
				? viewSelf.formData.cooling_control : {};
			var targetMode = cfg.mode || 'smart';
			var targetPwm = parseInt(cfg.stepless_pwm != null ? cfg.stepless_pwm : 192, 10);
			var targetSource = cfg.temp_id || 'cpu';

			var init = viewSelf.initialStatus || {};
			var initialMode = init.mode || 'smart';
			var initialPwm = parseInt(init.stepless_pwm != null ? init.stepless_pwm : 192, 10);
			var initialSource = init.temp_source || 'cpu';
			var needsInit = (init.uninitialized === true);
			shouldApply = needsInit || targetSource !== initialSource ||
				targetMode !== initialMode ||
				(targetMode === 'stepless' && targetPwm !== initialPwm);

			if (!shouldApply)
				return;

			var pwmArg = (targetMode === 'stepless') ? targetPwm : undefined;
			return callApplyConfig(targetMode, pwmArg, targetSource).then(function(res) {
				if (!res || res.code !== 0)
					throw new Error((res && res.error) ? res.error : 'RPC error');
			});
		}).then(function() {
			return callGetStatus().then(function(newStatus) {
				if (!newStatus || newStatus.code !== 0)
					throw new Error((newStatus && newStatus.error) ? newStatus.error : 'RPC error');

				viewSelf.initialStatus = newStatus;
				updateStatusDOM(newStatus);
				showBanner(null, E('p', _('Configuration has been applied.')), 3500, 'info');
			}).catch(function(err) {
				var msg = shouldApply
					? _('Configuration was applied, but status refresh failed: %s').format(err.message || err)
					: _('Fan status refresh failed: %s').format(err.message || err);
				showBanner(null, E('p', msg), 0, 'error');
			});
		}).catch(function(err) {
			showBanner(null, E('p', _('Failed to apply configuration: %s').format(err.message || err)), 0, 'error');
		}).then(function() {
			viewSelf.applyInProgress = false;
			poll.add(pollFanStatus, 5);
		});
	},

	handleSave: null,
	handleReset: null
});

'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require fs';
'require poll';

return view.extend({
	load: function() {
		return uci.load('nssqos');
	},

	render: function() {
		var map = new form.Map('nssqos', _('NSS 硬件 QoS'),
			_('在物理 WAN 设备上启用 NSS 硬件整形：上行 nsstbl + nssfq_codel，下行 ifb + nssmirred。ECM 硬件加速保持开启，不做软件 QoS。'));

		var section = map.section(form.NamedSection, 'main', 'main', _('限速设置'));

		var o = section.option(form.Flag, 'enabled', _('启用'),
			_('开启后开机自动应用；关闭会清理已有的 NSS 队列'));
		o.default = '0';
		o.rmempty = false;

		o = section.option(form.Value, 'wan', _('WAN 设备'),
			_('留空或 auto 自动识别物理 WAN 设备；也可手动填写如 wan'));
		o.placeholder = 'auto';
		o.default = 'auto';
		o.rmempty = false;

		o = section.option(form.Value, 'upload', _('上行限速 (kbps)'),
			_('0 表示不做上行整形；例如 100000 = 100 Mbps'));
		o.datatype = 'uinteger';
		o.default = '0';
		o.rmempty = false;

		o = section.option(form.Value, 'download', _('下行限速 (kbps)'),
			_('0 表示不做下行整形；下行通过 ifb + nssmirred 实现'));
		o.datatype = 'uinteger';
		o.default = '0';
		o.rmempty = false;

		o = section.option(form.Value, 'target', _('fq_codel 延迟目标'),
			_('默认 5ms，一般无需修改'));
		o.placeholder = '5ms';
		o.default = '5ms';

		o = section.option(form.Button, '_reapply', _('立即应用'),
			_('不修改配置，按当前设置重新下发一次队列'));
		o.inputtitle = _('重新应用');
		o.inputstyle = 'apply';
		o.onclick = function() {
			return fs.exec('/usr/sbin/nss-qos', ['restart']).then(function(res) {
				if (res && res.code)
					ui.addNotification(null, E('p', {}, _('应用失败: ') + (res.stderr || res.code)), 'error');
				else
					ui.addNotification(null, E('p', {}, _('QoS 已重新应用')));
			});
		};

		var status = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('运行状态')),
			E('pre', {
				'id': 'nss-qos-status',
				'style': 'white-space:pre-wrap;max-height:420px;overflow:auto;margin:0'
			}, _('读取中…'))
		]);

		var refresh = function() {
			return fs.exec('/usr/sbin/nss-qos', ['status']).then(function(res) {
				var el = document.getElementById('nss-qos-status');
				if (el)
					el.textContent = (res && res.stdout ? res.stdout : '').trim();
			}).catch(function() {});
		};

		poll.add(refresh, 5);
		refresh();

		return map.render().then(function(node) {
			return E('div', {}, [node, status]);
		});
	},

	handleSaveApply: function(ev, mode) {
		return this.handleSave(ev).then(function() {
			return uci.apply();
		}).then(function() {
			return fs.exec('/usr/sbin/nss-qos', ['restart']);
		}).then(function(res) {
			if (res && res.code)
				ui.addNotification(null, E('p', {}, _('QoS 应用失败: ') + (res.stderr || res.code)), 'error');
			else
				ui.addNotification(null, E('p', {}, _('QoS 已保存并应用')));
		});
	}
});

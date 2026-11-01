'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require fs';
'require poll';

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('nssqos'),
			fs.exec('/usr/sbin/nss-qos', ['list']).then(function(res) {
				var out = (res && res.stdout ? res.stdout : '').trim();
				var list = out.length ? out.split(/\s+/) : [];
				return list.length ? list : [ 'wan', 'lan1', 'lan2', 'lan3' ];
			}).catch(function() {
				return [ 'wan', 'lan1', 'lan2', 'lan3' ];
			})
		]);
	},

	render: function(data) {
		var ifaces = data[1];

		var map = new form.Map('nssqos', _('NSS 硬件 QoS'),
			_('按网口分别配置 NSS 硬件整形。每条规则可选择 wan/lan1/lan2/lan3；' +
			  '出方向使用 nsstbl+nssfq_codel，入方向使用 ifb+nssmirred。ECM 始终开启，不使用软件 QoS。'));

		var section = map.section(form.GridSection, 'rule', _('整形规则'));
		section.addremove = true;
		section.sortable = true;
		section.anonymous = false;
		section.addbtntitle = _('添加规则');

		var o = section.option(form.Flag, 'enabled', _('启用'));
		o.default = '0';
		o.rmempty = false;

		o = section.option(form.ListValue, 'iface', _('接口'), _('只列出 NSS 数据面网口（nss-dp）'));
		ifaces.forEach(function(i) {
			o.value(i, i + (i == 'wan' ? _('（WAN）') : _('（LAN）')));
		});
		o.rmempty = false;

		o = section.option(form.Value, 'egress', _('出方向 (kbps)'),
			_('WAN：上传限速；LAN：发往该口设备（下载）。0=不限'));
		o.datatype = 'uinteger';
		o.default = '0';
		o.rmempty = false;

		o = section.option(form.Value, 'ingress', _('入方向 (kbps)'),
			_('WAN：下载限速；LAN：该口设备发来（上传）。0=不限。LAN 入方向可能影响同网段互访'));
		o.datatype = 'uinteger';
		o.default = '0';
		o.rmempty = false;

		o = section.option(form.Value, 'target', _('fq_codel 延迟目标'));
		o.placeholder = '5ms';
		o.default = '5ms';

		var status = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('运行状态')),
			E('pre', {
				'id': 'nss-qos-status',
				'style': 'white-space:pre-wrap;max-height:480px;overflow:auto;margin:0'
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

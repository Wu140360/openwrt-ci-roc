'use strict';
'require view';
'require form';
'require fs';
'require uci';
'require ui';

function statusNode(status) {
	var text = '';

	if (status && status.stdout)
		text = status.stdout.trim();
	else if (status && status.stderr)
		text = status.stderr.trim();

	if (!text)
		text = _('Status unavailable');

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, [ _('Current status') ]),
		E('pre', {
			'style': 'white-space:pre-wrap; word-break:break-word; margin:0; padding:8px; background:var(--background-color-low, #f5f5f5); border-radius:4px'
		}, [ text ]),
		E('div', { 'class': 'cbi-section-actions' }, [
			E('a', {
				'href': L.url('admin/network/sqm'),
				'class': 'btn cbi-button cbi-button-action'
			}, [ _('Open SQM settings') ]), ' ',
			E('a', {
				'href': L.url('admin/services/eqos'),
				'class': 'btn cbi-button cbi-button-action'
			}, [ _('Open eqos settings') ]), ' ',
			E('button', {
				'class': 'cbi-button cbi-button-neutral',
				'click': function() { location.reload(); }
			}, [ _('Refresh') ])
		])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('qosswitch'),
			fs.exec('/usr/sbin/qos-switch', [ 'status' ]).catch(function(err) {
				return { code: -1, stdout: '', stderr: err.message };
			})
		]).then(function(res) {
			return { status: res[1] };
		});
	},

	render: function(data) {
		var m, s, o;
		var status = data ? data.status : null;

		m = new form.Map('qosswitch', _('QoS Mode Switch'),
			_('Switch between NSS hardware shaping, software shaping and no QoS. Software mode stops ECM hardware offload so the CPU shaper actually sees the packets.'));

		s = m.section(form.NamedSection, 'main', 'qosswitch', _('Operating mode'));
		s.anonymous = false;

		o = s.option(form.ListValue, 'mode', _('Mode'));
		o.widget = 'radio';
		o.orientation = 'vertical';
		o.value('off', _('Off — no QoS, ECM hardware acceleration enabled'));
		o.value('nss', _('Hardware QoS — NSS shaper, ECM enabled (recommended)'));
		o.value('soft', _('Software QoS — ECM stopped, CPU shaping'));
		o.default = 'off';
		o.rmempty = false;

		o = s.option(form.Value, 'wan_dev', _('WAN device'),
			_('auto resolves the physical device from network.wan; an explicit name is mainly used for status output.'));
		o.default = 'auto';
		o.placeholder = 'auto';
		o.rmempty = false;

		o = s.option(form.Value, 'download', _('Download bandwidth (kbit/s)'),
			_('0 or empty disables shaping in that direction. Both values are required for eqos.'));
		o.datatype = 'uinteger';
		o.placeholder = '100000';

		o = s.option(form.Value, 'upload', _('Upload bandwidth (kbit/s)'),
			_('0 or empty disables shaping in that direction. Both values are required for eqos.'));
		o.datatype = 'uinteger';
		o.placeholder = '20000';

		o = s.option(form.ListValue, 'soft_engine', _('Software engine'));
		o.widget = 'radio';
		o.orientation = 'vertical';
		o.value('sqm', _('SQM + Cake — best general purpose shaper'));
		o.value('eqos', _('eqos — per-IP/MAC limits on the LAN'));
		o.default = 'sqm';
		o.depends('mode', 'soft');

		return m.render().then(function(node) {
			var note = E('p', { 'class': 'cbi-section-descr' }, [
				_('NSS mode uses the nss-zk.qos script from sqm-scripts-nss. Software mode stops qca-nss-ecm first; returning to Off or NSS restores it. The detailed SQM and eqos settings remain available through the buttons below.')
			]);
			/* Keep the status block outside the form map so Map.save() redraws
			 * the form without removing the status output. */
			return E('div', {}, [ node, note, statusNode(status) ]);
		});
	},

	handleSaveApply: function(ev, mode) {
		return Promise.resolve(this.super('handleSave', [ ev ])).then(function() {
			return uci.apply();
		}).then(function() {
			return fs.exec('/etc/init.d/qosswitch', [ 'reload' ]);
		}).then(function(res) {
			var out = ((res && (res.stdout || res.stderr)) || '').trim();

			if (!res || res.code !== 0)
				throw new Error(out || _('The QoS service returned an error.'));

			ui.showModal(_('QoS mode applied'), [
				E('p', {}, [ _('The selected mode was applied. Current status:') ]),
				E('pre', {
					'style': 'white-space:pre-wrap; max-height:420px; overflow:auto'
				}, [ out || _('No status output.') ]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': function() {
							ui.hideModal();
							location.reload();
						}
					}, [ _('Refresh page') ]), ' ',
					E('button', {
						'class': 'cbi-button',
						'click': ui.hideModal
					}, [ _('Close') ])
				])
			]);
		}).catch(function(err) {
			ui.showModal(_('Apply failed'), [
				E('p', {}, [ _('The mode could not be applied. Check the error below and the system log.') ]),
				E('pre', {
					'style': 'white-space:pre-wrap; max-height:360px; overflow:auto'
				}, [ (err && err.message) || String(err) ]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'cbi-button',
						'click': ui.hideModal
					}, [ _('Close') ])
				])
			]);
		});
	}
});

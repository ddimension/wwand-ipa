'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require wwand.ipafmt as ipafmt';

/* eSIM fleet management (wwand-ipa): per modem, where the eIM polling stands,
   and a poll on request. Status through modem_plugin_status (read acl), the
   poll through modem_plugin (write acl): a poll can switch the active profile,
   and rpcd grants methods, not arguments. */

var callStatus = rpc.declare({ object: 'wwand', method: 'status', expect: { modems: {} } });
var callIpaStatus = rpc.declare({ object: 'wwand', method: 'modem_plugin_status',
	params: [ 'modem', 'plugin', 'op' ], expect: {} });
var callIpa = rpc.declare({ object: 'wwand', method: 'modem_plugin',
	params: [ 'modem', 'plugin', 'op' ], expect: {} });

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {}).then(function(modems) {
			var names = Object.keys(modems || {}).sort();

			return Promise.all(names.map(function(n) {
				return L.resolveDefault(callIpaStatus(n, 'ipa', 'status'), {});
			})).then(function(sts) {
				return names.map(function(n, i) { return { modem: n, st: sts[i] || {} }; });
			});
		});
	},

	renderModem: function(m) {
		var st = m.st;

		if (st.ok === false)
			/* array: the error string comes from the daemon */
			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ m.modem ]),
				E('p', {}, E('em', {}, [ _('Not available: %s').format(st.error || '?') ])),
			]);

		if (!st.enabled)
			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ m.modem ]),
				/* array: dom.append() puts a bare string through innerHTML
				   (luci.js:1394-1396, the anchor luci-app-wwand's esim.js
				   carries), and "<file>" would be parsed as a tag */
				E('p', {}, E('em', {}, [ _('Fleet management is off for this modem. Set it up with `wwandctl ipa %s eim <file>`, or options ipa and ipa_eim_config on its wwand_modem section.').format(m.modem) ])),
			]);

		var rows = ipafmt.rows(st).map(function(r) {
			/* arrays: ICCIDs and error strings come from the card and the eIM */
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '25%' }, [ r[0] ]),
				E('td', { 'class': 'td left' }, [ r[1] ]),
			]);
		});

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ m.modem ]),
			E('table', { 'class': 'table' }, rows),
			E('button', { 'class': 'btn cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(this, function() {
					return callIpa(m.modem, 'ipa', 'poll').then(function(res) {
						if (res && res.ok === false)
							ui.addNotification(null, E('p', {}, [ _('eIM poll not started: %s').format(res.error || '?') ]), 'warning');
						else
							ui.addNotification(null, E('p', {}, _('eIM poll started; reload the page for the result.')), 'info');
					});
				}) }, _('Poll now')),
		]);
	},

	render: function(modems) {
		var self = this;

		return E([], [
			E('h2', {}, _('eSIM fleet management')),
			E('div', { 'class': 'cbi-map-descr' }, _('An eIM (GSMA SGP.32) manages the profiles on the modem\'s eSIM: it is polled after the connection comes up and then periodically, and the profile changes it sends are applied here. Manual profile changes on a managed card are switched off.')),
		].concat(modems.length ? modems.map(function(m) { return self.renderModem(m); })
		                       : [ E('p', {}, E('em', {}, _('No modem managed by wwand.'))) ]));
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null,
});

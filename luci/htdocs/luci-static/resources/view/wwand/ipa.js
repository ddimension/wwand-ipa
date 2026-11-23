'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require wwand.ipafmt as ipafmt';

/* eSIM fleet management (wwand-ipa): per modem, where the eIM polling stands,
   a poll on request, and the plugin's options on its wwand_modem section in
   /etc/config/network. Status through modem_plugin_status (read acl), the
   poll through modem_plugin (write acl): a poll can switch the active profile,
   and rpcd grants methods, not arguments. Saving reloads wwand through its
   procd trigger on the network config (wwand files/wwand.init
   service_triggers); the plugin takes the new options without restarting the
   modem. */

var callStatus = rpc.declare({ object: 'wwand', method: 'status', expect: { modems: {} } });
var callIpaStatus = rpc.declare({ object: 'wwand', method: 'modem_plugin_status',
	params: [ 'modem', 'plugin', 'op' ], expect: {} });
var callIpa = rpc.declare({ object: 'wwand', method: 'modem_plugin',
	params: [ 'modem', 'plugin', 'op' ], expect: {} });

/* what the plugin passes to ipad on a command line, and refuses otherwise
   (plugins/ipa.uc safe_path, safe_id): checked here so a value the plugin
   would drop is not saved silently */
var SAFE_PATH = /^\/[A-Za-z0-9._\/-]+$/;
var SAFE_ID = /^[A-Za-z0-9._:-]+$/;

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {}).then(function(modems) {
			var names = Object.keys(modems || {}).sort();

			return Promise.all(names.map(function(n) {
				return L.resolveDefault(callIpaStatus(n, 'ipa', 'status'), {});
			})).then(function(sts) {
				var out = {};

				names.forEach(function(n, i) { out[n] = { euicc: modems[n].euicc, st: sts[i] || {} }; });
				return out;
			});
		});
	},

	/* the status table of one modem, by its section name (the daemon names a
	   modem after its wwand_modem section) */
	renderStatus: function(name, info) {
		if (!info)
			return E('p', {}, E('em', {}, _('Not running: the daemon has no modem of this name.')));

		var st = info.st || {};

		if (st.ok === false)
			/* array: the error string comes from the daemon */
			return E('p', {}, E('em', {}, [ _('Not available: %s').format(st.error || '?') ]));

		var rows = [];
		var ipa = ipafmt.ipa(info.euicc, st.enabled);

		if (ipa)
			rows.push([ _('IPA'), ipa[0], ipa[1] ]);

		rows = rows.concat(ipafmt.rows(st));

		var table = E('table', { 'class': 'table' }, rows.map(function(r) {
			/* arrays: dom.append() puts a bare string through innerHTML
			   (luci.js:1394-1396), and ICCIDs and error strings come from the
			   card and the eIM */
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '25%' }, [ r[0] ]),
				E('td', { 'class': 'td left' }, r[2] ? E('strong', { 'style': 'color:#c00' }, [ r[1] ]) : [ r[1] ]),
			]);
		}));

		if (!st.enabled)
			return E('div', {}, [ table,
				E('p', {}, E('em', {}, _('Fleet management is off for this modem. Switch it on below; a card that holds no eIM yet also needs an eIM configuration file.'))) ]);

		return E('div', {}, [ table,
			E('button', { 'class': 'btn cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(this, function() {
					return callIpa(name, 'ipa', 'poll').then(function(res) {
						if (res && res.ok === false)
							ui.addNotification(null, E('p', {}, [ _('eIM poll not started: %s').format(res.error || '?') ]), 'warning');
						else
							ui.addNotification(null, E('p', {}, _('eIM poll started; reload the page for the result.')), 'info');
					});
				}) }, _('Poll now')),
		]);
	},

	render: function(modems) {
		var self = this, m, s, o;

		m = new form.Map('network', _('eSIM fleet management'),
			_('An eIM (GSMA SGP.32) manages the profiles on the modem\'s eSIM: it is polled after the connection comes up and then periodically, and the profile changes it sends are applied here. Manual profile changes on a managed card are switched off.'));

		s = m.section(form.TypedSection, 'wwand_modem');
		s.anonymous = false;
		s.addremove = false;

		o = s.option(form.DummyValue, '_status', _('Status'));
		o.renderWidget = function(section_id) { return self.renderStatus(section_id, modems[section_id]); };

		o = s.option(form.Flag, 'ipa', _('Fleet management'),
			_('Poll the eIM with the router\'s IPA (ipad). An IoT eUICC that already holds an eIM needs nothing else: the eIM, its address and how its TLS is trusted are read from the card.'));

		/* the same option luci-app-wwand sets in the modem settings: an IoT
		   eUICC that runs its own IPA refuses the router until it is switched
		   to the router's (wwand docs/reference.md, "SGP.32 IoT cards") */
		o = s.option(form.ListValue, 'ipa_mode', _('SGP.32 IPA'),
			_('Who runs an SGP.32 IoT eUICC that also has its own IPA (IPAe). By default the card keeps its own IPA, and the router has no access to the card\'s profiles. "Router (IPAd)" makes the router announce its own IPA to the card. The card then turns its own IPA off and lets the router manage the profiles: eSIM page, lpac, eIM plugin.'));
		o.value('', _('Card (IPAe, default)'));
		o.value('ipad', _('Router (IPAd)'));
		o.optional = true;

		/* The options below show only with fleet management on. retain: LuCI
		   otherwise deletes a hidden option on save (form.js:2175
		   AbstractValue.parse, luci as of 2026-11-14), and switching management
		   off for a while would lose the interval, the eIM and the rest. */
		o = s.option(form.Value, 'ipa_interval', _('Poll interval'),
			_('Seconds between polls, at least 300. Each router waits up to a tenth longer, so a fleet does not poll in the same second. After a failed poll the next try comes after 600 s, doubling up to the interval.'));
		o.datatype = 'and(uinteger,min(300))';
		o.placeholder = '3600';
		o.depends('ipa', '1');
		o.retain = true;

		o = s.option(form.Value, 'ipa_eim_id', _('eIM'),
			_('Which eIM to poll when the card holds several (its eimId). Empty: the first with an address.'));
		o.depends('ipa', '1');
		o.retain = true;
		o.validate = function(sid, v) {
			return (v == '' || SAFE_ID.test(v)) ? true : _('Letters, digits and . _ : - only');
		};

		o = s.option(form.Value, 'ipa_eim_config', _('eIM configuration file'),
			_('Only for a card without an eIM: the file from the eIM operator (an absolute path on the router), stored on the card at the next poll. A card that has an eIM keeps it.'));
		o.depends('ipa', '1');
		o.retain = true;
		o.validate = function(sid, v) {
			return (v == '' || (SAFE_PATH.test(v) && v.indexOf('..') < 0)) ? true : _('An absolute path without ..');
		};

		o = s.option(form.ListValue, 'ipa_backend', _('Card type'),
			_('How the card is driven. Automatic asks the card whether it is an SGP.32 IoT eUICC; an SGP.22 card gets the SGP.32 functions emulated by the router.'));
		o.value('', _('Automatic'));
		o.value('iot', _('IoT eUICC (SGP.32)'));
		o.value('emu', _('SGP.22 card, emulated'));
		o.optional = true;
		o.depends('ipa', '1');
		o.retain = true;

		/* unset is on (plugins/ipa.uc cfg_of) */
		o = s.option(form.Flag, 'ipa_direct', _('Direct downloads'),
			_('Offer the eIM to download profiles from the SM-DP+ directly (through lpac).'));
		o.default = '1';
		o.depends('ipa', '1');
		o.retain = true;

		o = s.option(form.Flag, 'ipa_insecure', _('Skip TLS verification'),
			_('Do not verify the eIM\'s TLS certificate. Lab use only: anyone in the path could pose as the eIM and change the card\'s profiles.'));
		o.depends('ipa', '1');
		o.retain = true;

		return m.render();
	},
});

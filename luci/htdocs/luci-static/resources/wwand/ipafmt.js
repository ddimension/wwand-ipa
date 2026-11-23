'use strict';
'require baseclass';

/* Pure helpers for the eIM page (view/wwand/ipa.js), kept apart from the view
   so tools/test-ipafmt.js can check them without a DOM. */

/* seconds as 45s, 12m 0s, 3h 5m — the same shape luci-app-wwand's fmtDur uses */
function dur(s) {
	var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
	if (h) return '%dh %dm'.format(h, m);
	if (m) return '%dm %ds'.format(m, sec);
	return '%ds'.format(sec);
}

return baseclass.extend({
	/* Which IPA serves the card, from the daemon's eUICC probe (wwand status,
	   modems.<m>.euicc: { sgp32, ipae_supported, ipa }). [ text, warn ]: warn
	   is true when fleet management cannot work as configured — a card whose
	   own IPA (IPAe) runs refuses every ES10 command from the router. null:
	   no eUICC seen (yet). */
	ipa: function(euicc, enabled) {
		if (!euicc)
			return null;

		if (euicc.ipa == 'ipad')
			return [ euicc.ipae_supported ? _('router (IPAd) — the card\'s own IPA is off')
			                              : _('router (IPAd)'), false ];

		if (euicc.ipa == 'ipae')
			return [ _('the card\'s own IPA (IPAe) — the router has no access to the card. Set "SGP.32 IPA" to "Router (IPAd)" below to manage it from here.'), !!enabled ];

		if (euicc.sgp32 === false)
			return [ _('router — an SGP.22 card, whose SGP.32 functions the router emulates'), false ];

		return [ _('router'), false ];
	},

	/* The plugin's status (modem_plugin_status, plugin 'ipa') as [ label, text ]
	   rows. Its timestamps are on the DAEMON's clock and st.now is that clock,
	   so "ago" and "in" never mix it with the browser's. Outcome first, then
	   when it tries again: what someone opening this page wants to know. The
	   same order as `wwandctl ipa`. */
	rows: function(st) {
		if (!st || !st.enabled)
			return [];

		var now = st.now, rows = [];
		var n = function(v) { return +(v || 0); };

		rows.push([ _('State'), '%s · %d %s · %d %s'.format(st.state || '?',
			n(st.runs), n(st.runs) == 1 ? _('run') : _('runs'),
			n(st.profile_changes), n(st.profile_changes) == 1 ? _('profile change') : _('profile changes')) ]);

		if (st.last_end != null && now != null)
			rows.push([ _('Last run'), '%s · %s'.format(_('%s ago').format(dur(now - st.last_end)),
				st.last_ok ? _('ok')
				           : _('failed: %s').format(st.last_error || '?') +
				             (n(st.fails) > 1 ? ' ' + _('(%d in a row)').format(n(st.fails)) : '')) ]);

		if (st.interval != null)
			rows.push([ _('Interval'), dur(n(st.interval)) ]);

		if (st.next_due != null && now != null)
			rows.push([ _('Next poll'), st.next_due > now ? _('in %s').format(dur(st.next_due - now)) : _('due now') ]);
		else if (st.state == 'idle')
			rows.push([ _('Next poll'), _('once the connection is up') ]);

		if (st.eid) {
			var how = '';

			if (st.backend == 'emulated')
				how = ' · ' + _('SGP.22 card, emulated') +
					(st.key_fingerprint ? ' · ' + _('device key %s…').format(st.key_fingerprint.substr(0, 16)) : '');
			else if (st.backend == 'iot')
				how = ' · ' + _('IoT eUICC');

			rows.push([ _('Card'), 'EID ' + st.eid + how ]);
		}

		/* the eIM configurations on the card as the last run read them; the
		   same text as `wwandctl ipa` */
		if (Array.isArray(st.eims)) {
			var tls = { key: _('TLS: pinned key'), certificate: _('TLS: pinned certificate'),
			            configuration: _('TLS: from the configuration'), system: _('TLS: system CAs') };

			if (!st.eims.length)
				rows.push([ _('eIM config'), _('none on the card') ]);

			st.eims.forEach(function(e) {
				var parts = [ (e && e.id) || _('(no id)'), (e && e.fqdn) || _('no FQDN (not polled)') ];

				if (e && e.tls)
					parts.push(tls[e.tls] || 'TLS: ' + e.tls);

				rows.push([ _('eIM config'), parts.join(' · ') ]);
			});
		}

		/* where the enabled profile's APN came from and where it went: the
		   same text as `wwandctl ipa` */
		var cn = st.connectivity;

		if (cn && cn.iccid) {
			var what = (cn.source == 'card')
				? _('APN %s').format(cn.apn || _('(empty)')) + (cn.pdp_type ? ' · ' + cn.pdp_type : '')
				: _('none stated (%s)').format(cn.source || 'none');
			var where = (cn.reason == 'foreign') ? _('left to your wwand_sim %s').format(cn.section)
				: (cn.reason == 'exists') ? _('%s kept as it is').format(cn.section)
				: cn.section ? cn.section + (cn.written ? ' ' + _('(written)') : '')
				: _('not written');

			rows.push([ _('Connectivity'), '%s: %s → %s'.format(cn.iccid, what, where) ]);
		}

		var c = st.last_changes || {}, parts = [];

		(c.switched || []).forEach(function(sw) {
			parts.push((sw.rollback ? _('rolled back %s → %s') : _('switched %s → %s')).format(sw.from || '?', sw.to || '?'));
		});
		(c.installed || []).forEach(function(i) { parts.push(_('installed %s').format(i)); });
		(c.deleted || []).forEach(function(i) { parts.push(_('deleted %s').format(i)); });
		(c.downloads || []).forEach(function(d) { parts.push(d.ok ? _('downloaded') : _('download failed')); });

		if (parts.length)
			rows.push([ _('Last changes'), parts.join(' · ') ]);

		return rows;
	},
});

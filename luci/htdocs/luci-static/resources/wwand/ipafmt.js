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

		if (st.next_due != null && now != null)
			rows.push([ _('Next poll'), st.next_due > now ? _('in %s').format(dur(st.next_due - now)) : _('due now') ]);
		else if (st.state == 'idle')
			rows.push([ _('Next poll'), _('once the connection is up') ]);

		if (st.eid)
			rows.push([ _('Card'), 'EID ' + st.eid + (st.nvstate === false ? ' · ' + _('no eIM configuration stored yet') : '') ]);

		var c = st.last_changes || {}, parts = [];

		(c.switched || []).forEach(function(sw) {
			parts.push((sw.rollback ? _('rolled back %s → %s') : _('switched %s → %s')).format(sw.from || '?', sw.to || '?'));
		});
		(c.installed || []).forEach(function(i) { parts.push(_('installed %s').format(i)); });
		(c.deleted || []).forEach(function(i) { parts.push(_('deleted %s').format(i)); });

		if (parts.length)
			rows.push([ _('Last changes'), parts.join(' · ') ]);

		return rows;
	},
});

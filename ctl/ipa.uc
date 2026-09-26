// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// `wwandctl ipa`: eSIM fleet management from the command line. A wwandctl
// command from an optional package (installed at /usr/share/ucode/wwand/ctl/
// ipa.uc); wwandctl hands it { call, call_ok, status, resolve_modem }.
//
// Plain script: require() returns { run, help } plus the pure formatters the
// tests reach.

'use strict';

import * as fs from 'fs';
import * as libuci from 'uci';

// A duration as the operator wants to read it: 45 s, 12 min, 3 h 5 min.
function span(sec)
{
	sec = int(sec);

	if (sec < 90)
		return sprintf('%d s', sec);

	if (sec < 5400)
		return sprintf('%d min', int((sec + 30) / 60));

	let h = int(sec / 3600), m = int((sec % 3600) / 60);

	return m ? sprintf('%d h %d min', h, m) : sprintf('%d h', h);
}

// `wwandctl ipa`: the eIM poll state (ubus modem_ipa status) as lines of
// [ label, text ]. `now` is the daemon's clock, which the timestamps come
// from (time(), seconds). What an operator asks first is "did it work, and
// when does it try again", so those lead.
function ipa_lines(st, now)
{
	if (type(st) != 'object')
		return [];

	let out = [];

	if (!st.enabled)
		return [ [ 'eIM', 'not enabled on this modem (option ipa)' ] ];

	push(out, [ 'eIM', sprintf('%s · %d run%s · %d profile change%s', st.state ?? '?',
		+(st.runs ?? 0), (st.runs == 1) ? '' : 's',
		+(st.profile_changes ?? 0), (st.profile_changes == 1) ? '' : 's') ]);

	if (st.last_end != null)
		push(out, [ 'last run', sprintf('%s ago · %s', span(now - st.last_end),
			st.last_ok ? 'ok'
			           : sprintf('failed: %s%s', st.last_error ?? '?',
			                     (+(st.fails ?? 0) > 1) ? sprintf(' (%d in a row)', st.fails) : '')) ]);

	if (st.next_due != null)
		push(out, [ 'next poll', (st.next_due > now) ? sprintf('in %s', span(st.next_due - now)) : 'due now' ]);
	else if (st.state == 'idle')
		push(out, [ 'next poll', 'once the connection is up' ]);

	if (st.eid)
		push(out, [ 'card', sprintf('EID %s%s', st.eid,
			(st.nvstate === false) ? ' · no eIM configuration stored yet' : '') ]);

	let c = st.last_changes, parts = [];

	for (let sw in (c?.switched ?? []))
		push(parts, sprintf('%s %s → %s', sw.rollback ? 'rolled back' : 'switched', sw.from ?? '?', sw.to ?? '?'));

	for (let i in (c?.installed ?? []))
		push(parts, 'installed ' + i);

	for (let i in (c?.deleted ?? []))
		push(parts, 'deleted ' + i);

	if (length(parts))
		push(out, [ 'last changes', join(' · ', parts) ]);

	return out;
}

// What an eIM configuration file is, from its first two bytes: the forms the
// assistant loads (onomondo-ipa ipad.c:224-229, commit 6aaeb38, 2026-09-01),
// an AddInitialEimRequest (tag BF57) or a GetEimConfigurationDataResponse
// (BF55, the same structure under another tag). Anything else — a PEM file,
// a hex dump, a JSON export — is refused HERE, because the assistant would
// only fail on it at the next poll, in the syslog, on a router nobody watches.
function eim_config_kind(data)
{
	if (type(data) != 'string' || length(data) < 4 || ord(data, 0) != 0xbf)
		return null;

	switch (ord(data, 1)) {
	case 0x57: return 'AddInitialEimRequest';
	case 0x55: return 'GetEimConfigurationDataResponse';
	}

	return null;
}


// the plugin's status for one modem, through the daemon's plugin method
let ipa_status = (ctx, modem) =>
	ctx.call_ok('modem_plugin', { modem: modem, plugin: 'ipa', op: 'status' });

// Point the modem at an eIM: the file goes to /etc/wwand/ipa (kept across
// sysupgrade), the options into /etc/config/network, and the daemon reloads —
// without a modem restart, a plugin's options are outside the modem's reload
// signature.
function set_eim(ctx, modem, src)
{
	// the options live on the modem's wwand_modem section; a modem from an
	// old-style configuration (the compat layer) has none, and a set on a
	// missing section silently does nothing — say so instead
	let cur = libuci.cursor();

	if (cur.get('network', modem) != 'wwand_modem')
		die(sprintf('modem %s has no `config wwand_modem` section in /etc/config/network — migrate the configuration first (/usr/libexec/wwand/migrate)', modem));

	let data = fs.readfile(src);

	if (data == null)
		die(sprintf('cannot read %s', src));

	let kind = eim_config_kind(data);

	if (!kind)
		die(sprintf('%s is not an eIM configuration: expected BER starting BF57 (AddInitialEimRequest) or BF55 (GetEimConfigurationDataResponse)', src));

	let dst = sprintf('/etc/wwand/ipa/%s-eim.ber', modem);

	fs.mkdir('/etc/wwand');
	fs.mkdir('/etc/wwand/ipa');

	if (src != dst) {
		let f = fs.open(dst, 'w');

		if (!f || f.write(data) == null)
			die(sprintf('cannot write %s', dst));

		f.close();
	}

	fs.chmod(dst, 0o600);

	cur.set('network', modem, 'ipa', '1');
	cur.set('network', modem, 'ipa_eim_config', dst);

	if (!cur.commit('network'))
		die('could not commit /etc/config/network');

	ctx.call_ok('reload', {});
	printf('modem %s: eIM configuration %s (%s), fleet management on\n', modem, dst, kind);

	// The file only reaches a card with no stored state yet; say so now, not
	// on the first poll that quietly keeps the old eIM. The EID from the eIM
	// runs if there were any, else from the status page's eSIM read — on a
	// first setup there have been no runs to know it from.
	let ist = ctx.call('modem_plugin', { modem: modem, plugin: 'ipa', op: 'status' });
	let eid = ist?.eid ?? ctx.status().modems[modem]?.esim?.eid;
	let nv = eid ? sprintf('/etc/wwand/ipa/%s.nvstate', uc(eid)) : null;

	if (nv && fs.access(nv))
		printf('note: card %s already has an eIM configuration stored (%s); it keeps that one\n', eid, nv);
	else if (!eid)
		printf('note: the card\'s EID is not known yet; if it was provisioned before, it keeps its stored eIM\n');
}

return {
	span: span,
	ipa_lines: ipa_lines,
	eim_config_kind: eim_config_kind,

	help: [
		'ipa [modem] [status|poll]             eIM fleet management: state, or poll now',
		'ipa [modem] eim <file>                set the eIM (BER AddInitialEimRequest) and enable it',
	],

	run: function(ctx, args) {
		let r = ctx.resolve_modem(ctx.status(), args[0]);
		let rest = r.consumed ? slice(args, 1) : args;
		let op = rest[0] ?? 'status';

		switch (op) {
		case 'status': {
			let st = ipa_status(ctx, r.modem);

			for (let l in ipa_lines(st, st.now ?? time()))
				printf('%-13s%s\n', l[0], l[1]);

			break;
		}

		case 'poll':
			ctx.call_ok('modem_plugin', { modem: r.modem, plugin: 'ipa', op: 'poll' });
			printf('eIM poll started — `wwandctl ipa` shows how it went\n');
			break;

		case 'eim':
			if (!length(rest[1] ?? ''))
				die('usage: wwandctl ipa [modem] eim <file>   (a BER AddInitialEimRequest from the eIM operator)');

			set_eim(ctx, r.modem, rest[1]);
			break;

		default:
			die('usage: wwandctl ipa [modem] [status|poll|eim <file>]');
		}
	},
};

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

	if (st.eid) {
		let how = (st.backend == 'emulated')
			? sprintf(' · SGP.22 card, emulated%s', st.key_fingerprint
				? sprintf(' · device key %s…', substr(st.key_fingerprint, 0, 16)) : '')
			: (st.backend == 'iot') ? ' · IoT eUICC' : '';

		push(out, [ 'card', sprintf('EID %s%s', st.eid, how) ]);
	}

	let cn = st.connectivity;

	if (cn?.iccid) {
		let what = (cn.source == 'card')
			? sprintf('apn %s%s', cn.apn ?? '(empty)', cn.pdp_type ? sprintf(' · %s', cn.pdp_type) : '')
			: sprintf('none stated (%s)', cn.source ?? 'none');
		let where = (cn.reason == 'foreign') ? sprintf('left to your wwand_sim %s', cn.section)
			: (cn.reason == 'exists') ? sprintf('%s kept as it is', cn.section)
			: cn.section ? sprintf('%s%s', cn.section, cn.written ? ' (written)' : '')
			: 'not written';

		push(out, [ 'connectivity', sprintf('%s: %s → %s', cn.iccid, what, where) ]);
	}

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

// What an eIM configuration file is, from its first bytes: the forms ipad
// provisions from (ipad ipa.c ipa_add_initial_eim), an AddInitialEimRequest
// (tag BF57, what `eimctl eim-config` writes), a GetEimConfigurationDataResponse
// (BF55, the same list under another tag) or one bare EimConfigurationData
// (a SEQUENCE, 30). Anything else — a PEM file, a hex dump, a JSON export — is
// refused HERE, because the assistant would only fail on it at the next poll,
// in the syslog, on a router nobody watches.
function eim_config_kind(data)
{
	if (type(data) != 'string' || length(data) < 4)
		return null;

	// a SEQUENCE that starts with eimId [0]: 30 len 80 (short or long form)
	if (ord(data, 0) == 0x30 && (ord(data, 2) == 0x80 || (ord(data, 1) == 0x81 && ord(data, 3) == 0x80) ||
	                             (ord(data, 1) == 0x82 && ord(data, 4) == 0x80)))
		return 'EimConfigurationData';

	if (ord(data, 0) != 0xbf)
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

// --- non-interactive commands: provision, poll, info, reset --------------------
//
// For scripts (the eIM lab's target driver, a bulk station): one JSON line on
// stdout, human messages on stderr, and an exit status that says what
// happened:
//   0  done
//   1  failed (the eIM or the network, the card, a bad argument)
//   2  the eIM refused to bind the card (403, eIM decision D-69)
//   3  not supported here (the assistant or wwand-esim not installed)
const EXIT_OK = 0, EXIT_FAIL = 1, EXIT_REFUSED = 2, EXIT_UNSUPPORTED = 3;

// ipad's own exit status when the eIM refused the binding (ipad main.c)
const IPAD_BIND_REFUSED = 4;

// plugin errors that mean "this router cannot do it", not "it went wrong"
const UNSUPPORTED = [ 'ipa_not_installed', 'esim_not_installed', 'no_such_plugin', 'invalid_op' ];

// sys: { sleep(s), now(), head(path, n), exists(path), unlink(path),
//        cursor(), out(line), err(msg) } — injectable for the tests
function sys_of(sys)
{
	sys = sys ?? {};

	return {
		sleep: sys.sleep ?? ((s) => system(sprintf('sleep %d', s))),
		now: sys.now ?? (() => time()),
		head: sys.head ?? ((p, n) => { let f = fs.open(p, 'r'); let d = f?.read(n); f?.close(); return d; }),
		exists: sys.exists ?? ((p) => fs.access(p) == true),
		unlink: sys.unlink ?? ((p) => fs.unlink(p)),
		cursor: sys.cursor ?? (() => libuci.cursor()),
		out: sys.out ?? ((l) => print(l)),
		err: sys.err ?? ((m) => warn(m)),
	};
}

function emit(sys, res, code)
{
	sys.out(sprintf('%J\n', res));
	return code;
}

// a plugin error as the JSON result and the exit status for it
function fail(sys, r, extra)
{
	let err = r?.detail ?? r?.error ?? 'failed';

	if (type(err) != 'string')
		err = sprintf('%J', err);

	sys.err(sprintf('wwandctl ipa: %s\n', err));

	return emit(sys, { result: 'error', error: err, ...(extra ?? {}) },
		(index(UNSUPPORTED, r?.error) >= 0) ? EXIT_UNSUPPORTED : EXIT_FAIL);
}

// A plugin op that needs the card; while another run holds it (a scheduled
// poll, lpac), waited for until `until` rather than failed: the caller asked
// for this op, not for a race with the schedule.
function op_wait(ctx, modem, op, args, until, sys)
{
	for (;;) {
		let r = ctx.call('modem_plugin', { modem: modem, plugin: 'ipa', op: op, args: args ?? {} });

		if (r?.ok !== false || r.error != 'busy' || sys.now() >= until)
			return r;

		sys.sleep(2);
	}
}

// The eIM's provisioning bundle (eim-ipad-provision/1, D-69) from its first
// bytes: a flat JSON object whose first field is the format. Only the start
// is read — the rest is a private key, and this process has no business
// holding it.
function is_bundle(head)
{
	return type(head) == 'string' && !!match(head, /^[ \t\r\n]*\{[ \t\r\n]*"format"[ \t]*:[ \t]*"eim-ipad-provision\/1"/);
}

// what the plugin's info answers, as the JSON line (the driver's `info`)
let info_line = (r) => ({
	eid: r?.eid, card_type: r?.card_type, bound: r?.bound, bind: r?.bind, counter: r?.counter,
	key_fingerprint: r?.key_fingerprint, last_poll: r?.last_poll, last_error: r?.last_error,
});

// `ipa <modem> provision <bundle>`: the assistant stores the eIM configuration
// and the device key and deletes the file; the card binds itself at its next
// poll. Fleet management is switched on (option ipa), so that poll happens.
function provision(ctx, modem, args, sys)
{
	sys = sys_of(sys);

	let file = args[0] ?? '';

	if (!length(file)) {
		sys.err('usage: wwandctl ipa [modem] provision <bundle>   (eim-ipad-provision/1 from the eIM)\n');
		return emit(sys, { result: 'error', error: 'usage' }, EXIT_FAIL);
	}

	// the daemon runs the assistant: a path of this shell's, made absolute
	if (substr(file, 0, 1) != '/')
		file = sprintf('%s/%s', fs.getcwd(), file);

	let head = sys.head(file, 64);

	if (head == null)
		return fail(sys, { error: sprintf('cannot read %s', file) });

	if (!is_bundle(head))
		return fail(sys, { error: sprintf('%s is not an eim-ipad-provision/1 bundle (a bare eIM configuration goes through `wwandctl ipa %s eim <file>`)', file, modem) });

	let cur = sys.cursor();

	if (cur.get('network', modem) != 'wwand_modem')
		return fail(sys, { error: sprintf('modem %s has no `config wwand_modem` section in /etc/config/network — migrate the configuration first (/usr/libexec/wwand/migrate)', modem) });

	let r = op_wait(ctx, modem, 'provision', { file: file }, sys.now() + 120, sys);

	if (r?.ok === false) {
		// the assistant keeps a bundle it could not store, for a retry; it
		// holds a private key, so say where it is
		let kept = sys.exists(file);

		if (kept)
			sys.err(sprintf('wwandctl ipa: the bundle is still at %s — it holds a private key: retry, or delete it\n', file));

		return fail(sys, r, { bundle_kept: kept ? file : null });
	}

	// stored, but the assistant could not delete it: once more, and said
	let deleted = !sys.exists(file) || (sys.unlink(file) && !sys.exists(file));

	if (!deleted)
		sys.err(sprintf('wwandctl ipa: could not delete %s — it holds a private key: delete it by hand\n', file));

	if (cur.get('network', modem, 'ipa') != '1') {
		cur.set('network', modem, 'ipa', '1');

		if (!cur.commit('network'))
			return fail(sys, { error: 'provisioned, but could not commit option ipa to /etc/config/network' });

		ctx.call_ok('reload', {});
	}

	sys.err(sprintf('modem %s: provisioned%s; fleet management on\n', modem,
		(r?.bind == 'pending') ? ', the card binds itself at the eIM on its next poll' : ''));

	return emit(sys, { result: 'ok', ...info_line(r), bundle_deleted: deleted }, EXIT_OK);
}

// `ipa <modem> poll [--timeout S]`: a poll now, waited for until it ends (the
// assistant stops at noEimPackageAvailable). A run already under way (the
// schedule's) is waited out first, then ours starts: the caller wants a poll
// that begins after it asked — a package queued a moment ago may have missed
// the running one.
function poll_wait(ctx, modem, args, sys)
{
	sys = sys_of(sys);

	let ti = index(args, '--timeout');
	let timeout = (ti >= 0) ? +(args[ti + 1] ?? 0) : 300;

	if (!(timeout > 0))
		return fail(sys, { error: 'usage: wwandctl ipa [modem] poll [--timeout SECONDS]' });

	let until = sys.now() + timeout;
	let status = () => ctx.call('modem_plugin', { modem: modem, plugin: 'ipa', op: 'status' });
	let st, before;

	for (;;) {
		st = status();

		if (st?.ok === false)
			return fail(sys, st);

		if (!st.enabled)
			return fail(sys, { error: 'fleet management is off on this modem (option ipa): provision a bundle or set an eIM first' });

		if (st.state == 'idle') {
			before = st.runs ?? 0;

			let r = ctx.call('modem_plugin', { modem: modem, plugin: 'ipa', op: 'poll' });

			if (r?.ok !== false)
				break;

			if (r.error != 'busy')
				return fail(sys, r);
		}

		if (sys.now() >= until)
			return fail(sys, { error: sprintf('timeout: the card stayed busy for %d s', timeout) });

		sys.sleep(2);
	}

	for (;;) {
		sys.sleep(1);
		st = status();

		if (st?.ok === false)
			return fail(sys, st);

		if ((st.runs ?? 0) > before && st.state == 'idle')
			break;

		if (sys.now() >= until)
			return fail(sys, { error: sprintf('timeout: the run did not end within %d s (state %s)', timeout, st.state ?? '?') });
	}

	let lp = st.last_poll, sm = lp?.summary;
	let res = {
		result: lp?.ok ? 'ok' : 'error',
		packages: sm?.packages,
		results: sm?.acknowledged,
		notifications: sm?.notifications,
		bound: (st.backend == 'emulated') ? (st.bind == 'done') : null,
		bind: st.bind,
		eid: st.eid,
		error: lp?.ok ? null : (lp?.error ?? st.last_error ?? 'failed'),
	};

	if (!lp?.ok)
		sys.err(sprintf('wwandctl ipa: poll failed: %s\n', res.error));

	return emit(sys, res, lp?.ok ? EXIT_OK : (sm?.code == IPAD_BIND_REFUSED) ? EXIT_REFUSED : EXIT_FAIL);
}

// `ipa <modem> info`: the card as the assistant reads it now
function info(ctx, modem, sys)
{
	sys = sys_of(sys);

	let r = op_wait(ctx, modem, 'info', {}, sys.now() + 120, sys);

	return (r?.ok === false) ? fail(sys, r) : emit(sys, info_line(r), EXIT_OK);
}

// `ipa <modem> reset`: forget the eIM configuration, the emulation state, the
// device key and the binding. The uci options stay as they are.
function reset(ctx, modem, sys)
{
	sys = sys_of(sys);

	let r = op_wait(ctx, modem, 'reset', {}, sys.now() + 120, sys);

	if (r?.ok === false)
		return fail(sys, r);

	let cur = sys.cursor();

	if (cur.get('network', modem, 'ipa') == '1' && !length(cur.get('network', modem, 'ipa_eim_config') ?? ''))
		sys.err(sprintf('modem %s: reset; fleet management is still on and polls fail (no_eim_config) until a new bundle is provisioned\n', modem));
	else
		sys.err(sprintf('modem %s: reset\n', modem));

	return emit(sys, { result: 'ok' }, EXIT_OK);
}

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
		die(sprintf('%s is not an eIM configuration: expected DER starting BF57 (AddInitialEimRequest), BF55 (GetEimConfigurationDataResponse) or 30 (EimConfigurationData)', src));

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

	// A card that already has an eIM keeps it: the file only reaches a card
	// without one (ipad provisions on its "no eIM" exit), and changing the eIM
	// of a card that has one is the eIM's business (its eCO packages). Said
	// now, not left for a poll that quietly keeps the old one.
	printf('note: the file is stored on the card at the next poll, if the card has no eIM yet; one that has keeps it\n');
}

return {
	span: span,
	ipa_lines: ipa_lines,
	eim_config_kind: eim_config_kind,
	is_bundle: is_bundle,
	provision: provision,
	poll_wait: poll_wait,
	info: info,
	reset: reset,

	help: [
		'ipa [modem] [status]                  eIM fleet management: state, schedule, the card',
		'ipa [modem] eim <file>                set the eIM (DER AddInitialEimRequest) and enable it',
		'ipa [modem] export <file>             the eIM import file of an emulated card (device key)',
		'ipa [modem] provision <bundle>        store an eIM bundle (eim-ipad-provision/1) and enable; JSON result',
		'ipa [modem] poll [--timeout S]        poll now, wait for the end of the run (default 300 s); JSON result',
		'ipa [modem] poll --no-wait            only start the poll',
		'ipa [modem] info                      the card now: EID, device key, binding, counter; JSON',
		'ipa [modem] reset                     forget eIM configuration, state and device key; JSON result',
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
			// waits for the run and says how it went (what a script and a
			// person at the console both want); --no-wait only starts it
			if (index(rest, '--no-wait') < 0)
				exit(poll_wait(ctx, r.modem, slice(rest, 1)));

			ctx.call_ok('modem_plugin', { modem: r.modem, plugin: 'ipa', op: 'poll' });
			printf('eIM poll started — `wwandctl ipa` shows how it went\n');
			break;

		case 'provision':
			exit(provision(ctx, r.modem, slice(rest, 1)));

		case 'info':
			exit(info(ctx, r.modem));

		case 'reset':
			exit(reset(ctx, r.modem));

		case 'eim':
			if (!length(rest[1] ?? ''))
				die('usage: wwandctl ipa [modem] eim <file>   (a BER AddInitialEimRequest from the eIM operator)');

			set_eim(ctx, r.modem, rest[1]);
			break;

		case 'export': {
			let f = rest[1] ?? '';

			if (!length(f))
				die('usage: wwandctl ipa [modem] export <file>   (for eimctl euicc import)');

			// the daemon writes it: a path of this shell's, made absolute
			if (substr(f, 0, 1) != '/')
				f = sprintf('%s/%s', fs.getcwd(), f);

			let res = ctx.call_ok('modem_plugin', { modem: r.modem, plugin: 'ipa', op: 'export', args: { file: f } });

			printf('%s written — import it on the eIM: eimctl euicc import %s\n', res?.file ?? f, res?.file ?? f);
			break;
		}

		default:
			die('usage: wwandctl ipa [modem] [status|poll [--timeout S|--no-wait]|eim <file>|export <file>|provision <bundle>|info|reset]');
		}
	},
};

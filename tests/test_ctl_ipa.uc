// wwand-ipa tests — `wwandctl ipa`: its formatters and the eIM file check.

'use strict';

import { eq, ok, done } from './lib/check.uc';

let ctl = require('wwand.ctl.ipa');

// --- ipa_lines: `wwandctl ipa` -------------------------------------------------
{
	eq(ctl.ipa_lines({ enabled: false }, 0), [ [ 'eIM', 'not enabled on this modem (option ipa)' ] ],
	   'ipa: a modem without option ipa says so, and nothing else');

	let st = { enabled: true, state: 'idle', runs: 4, profile_changes: 1,
	           last_end: 1000, last_ok: false, last_error: 'exit 234', fails: 2,
	           next_due: 1000 + 1200, eid: 'E1', backend: 'emulated', key_fingerprint: '0123456789ABCDEF0123',
	           connectivity: { iccid: '8949', source: 'emulated: none', section: 'wwsim_8949', written: true },
	           last_changes: { switched: [ { from: 'A', to: 'B', rollback: false },
	                                       { from: 'B', to: 'A', rollback: true } ],
	                           installed: [ 'C' ], deleted: [] } };

	eq(ctl.ipa_lines(st, 1300), [
		[ 'eIM', 'idle · 4 runs · 1 profile change' ],
		[ 'last run', '5 min ago · failed: exit 234 (2 in a row)' ],
		[ 'next poll', 'in 15 min' ],
		[ 'card', 'EID E1 · SGP.22 card, emulated · device key 0123456789ABCDEF…' ],
		[ 'connectivity', '8949: none stated (emulated: none) → wwsim_8949 (written)' ],
		[ 'last changes', 'switched A → B · rolled back B → A · installed C' ],
	], 'ipa: outcome first, then when it tries again, the card and what the last run did');

	eq(ctl.ipa_lines({ enabled: true, state: 'idle', runs: 0, profile_changes: 0 }, 0)[1],
	   [ 'next poll', 'once the connection is up' ], 'ipa: offline, the next poll waits for the connection');
	eq(ctl.ipa_lines({ ...st, next_due: 1000 }, 1300)[2], [ 'next poll', 'due now' ], 'ipa: an overdue poll is due now');
	eq(ctl.ipa_lines({ ...st, last_ok: true, fails: 0, last_end: 0 }, 3 * 3600 + 5 * 60)[1],
	   [ 'last run', '3 h 5 min ago · ok' ], 'ipa: a good run, hours ago');
}

// --- eim_config_kind: what `wwandctl ipa eim <file>` accepts ------------------
eq(ctl.eim_config_kind('\xbf\x57\x7c\xa0'), 'AddInitialEimRequest', 'eim file: BF57 is the initial eIM request');
eq(ctl.eim_config_kind('\xbf\x55\x7c\xa0'), 'GetEimConfigurationDataResponse', 'eim file: BF55 is accepted as the same structure');
eq(ctl.eim_config_kind('-----BEGIN PUBLIC KEY-----'), null, 'eim file: a PEM key is not a configuration');
eq(ctl.eim_config_kind('BF577CA0'), null, 'eim file: a HEX dump of one is not one either');
eq(ctl.eim_config_kind('\xbf\x2d\x00\x00'), null, 'eim file: another ES10 structure is refused');
eq(ctl.eim_config_kind(null), null, 'eim file: nothing read, nothing accepted');
eq(ctl.eim_config_kind('\x30\x0a\x80\x03eim'), 'EimConfigurationData', 'eim file: a bare EimConfigurationData');
eq(ctl.eim_config_kind('\x30\x81\x88\x80\x0f'), 'EimConfigurationData', 'eim file: ...with a long length');
eq(ctl.eim_config_kind('\x30\x0a\x02\x01\x00'), null, 'eim file: some other SEQUENCE is not one');

{
	let cn = (c) => ctl.ipa_lines({ enabled: true, state: 'idle', runs: 1, profile_changes: 0, connectivity: c }, 0)[2];

	eq(cn({ iccid: '8949', source: 'card', apn: 'iot.ex', pdp_type: 'ipv4', section: 'wwsim_8949', written: true }),
	   [ 'connectivity', '8949: apn iot.ex · ipv4 → wwsim_8949 (written)' ], 'connectivity: what the card stated, and where it went');
	eq(cn({ iccid: '8949', source: 'card', apn: 'iot.ex', section: 'mysim', reason: 'foreign' }),
	   [ 'connectivity', '8949: apn iot.ex → left to your wwand_sim mysim' ], 'connectivity: a hand-written section is left alone');
}


ok(type(ctl.run) == 'function' && length(ctl.help) == 9, 'ctl: the shape wwandctl loads (run, help)');

// --- provision / poll / info / reset: the scripted commands --------------------
// A fake daemon (ctx.call answers per op from a script) and a fake system
// (clock, files, uci, stdout/stderr captured). The last stdout line is JSON,
// the exit status says what happened (0 ok, 1 failed, 2 refused, 3 unsupported).

eq(ctl.is_bundle('{"format":"eim-ipad-provision/1","issuance_id":"'), true, 'bundle: the eIM\'s file, by its first field');
eq(ctl.is_bundle(' \n{ "format" : "eim-ipad-provision/1"'), true, 'bundle: whitespace tolerated');
eq(ctl.is_bundle('{"format":"eim-euicc-import/1"'), false, 'bundle: the import file is not one');
eq(ctl.is_bundle('\xbf\x57\x7c'), false, 'bundle: DER is not one');
eq(ctl.is_bundle(null), false, 'bundle: nothing read');

let mkenv = (answers, over) => {
	let e = { calls: [], out: [], err: [], clock: 1000, files: {}, uci: { m1: { '.type': 'wwand_modem' } },
	          commits: 0, heads: [] };

	e.ctx = {
		call: (method, args) => {
			push(e.calls, [ method, args?.op, args?.args ]);

			let a = answers[args?.op ?? method];

			return (type(a) == 'function') ? a(e) : (a ?? { ok: true });
		},
		call_ok: (method, args) => { push(e.calls, [ method ]); return { ok: true }; },
	};
	e.sys = {
		sleep: (s) => { e.clock += s; },
		now: () => e.clock,
		head: (p, n) => { push(e.heads, n); return e.files[p] ? substr(e.files[p], 0, n) : null; },
		exists: (p) => e.files[p] != null,
		unlink: (p) => { delete e.files[p]; return true; },
		cursor: () => ({
			get: (c, sec, opt) => opt ? e.uci[sec]?.[opt] : e.uci[sec]?.['.type'],
			set: (c, sec, opt, v) => { e.uci[sec][opt] = v; },
			commit: () => { e.commits++; return true; },
		}),
		out: (l) => push(e.out, l),
		err: (m) => push(e.err, m),
		...(over ?? {}),
	};
	e.json = () => json(e.out[length(e.out) - 1]);

	return e;
};

const BUNDLE = '{"format":"eim-ipad-provision/1","issuance_id":"u1","eim_configuration":"MAO=","device_key":"SECRETKEY","counter":0,"expires_at":"2027-01-01T00:00:00Z"}';
const INFO = { eid: 'E1', card_type: 'emulated', bind: 'pending', bound: false, counter: 0, key_fingerprint: 'AB12' };

{
	// provision: the assistant stores it (and deletes the file), option ipa on
	let e = mkenv({ provision: (e) => { delete e.files['/tmp/b.json']; return { ok: true, ...INFO, file: '/tmp/b.json' }; } });

	e.files['/tmp/b.json'] = BUNDLE;
	eq(ctl.provision(e.ctx, 'm1', [ '/tmp/b.json' ], e.sys), 0, 'provision: exit 0');
	eq(e.calls[0], [ 'modem_plugin', 'provision', { file: '/tmp/b.json' } ], 'provision: the plugin op with the file');
	eq(e.json(), { result: 'ok', eid: 'E1', card_type: 'emulated', bound: false, bind: 'pending', counter: 0,
	               key_fingerprint: 'AB12', last_poll: null, last_error: null, bundle_deleted: true },
	   'provision: the JSON line: the card, binding pending, the bundle gone');
	eq(e.uci.m1.ipa, '1', 'provision: fleet management switched on');
	ok(e.commits == 1 && e.calls[1][0] == 'reload', 'provision: committed and reloaded');
	ok(e.heads[0] <= 64, 'provision: only the start of the bundle is read here');
	ok(index(join('', e.out) + join('', e.err), 'SECRETKEY') < 0, 'provision: nothing of the key is printed');

	// a refusal of the assistant: the bundle stays for a retry, and that is said
	e = mkenv({ provision: { ok: false, error: 'ipa', detail: 'bundle u1 expired at 2024-01-01T00:00:00Z' } });
	e.files['/tmp/b.json'] = BUNDLE;
	eq(ctl.provision(e.ctx, 'm1', [ '/tmp/b.json' ], e.sys), 1, 'provision failed: exit 1');
	eq(e.json(), { result: 'error', error: 'bundle u1 expired at 2024-01-01T00:00:00Z', bundle_kept: '/tmp/b.json' },
	   'provision failed: why, and where the bundle still is');
	ok(index(join('', e.err), 'private key') >= 0, 'provision failed: the kept bundle is flagged as a secret');
	eq(e.uci.m1.ipa, null, 'provision failed: option ipa untouched');

	// not a bundle, not a wwand_modem, busy card, no assistant
	e = mkenv({});
	e.files['/tmp/e.ber'] = '\xbf\x57\x7c\xa0';
	eq(ctl.provision(e.ctx, 'm1', [ '/tmp/e.ber' ], e.sys), 1, 'provision: a bare eIM configuration is refused here');
	eq(length(e.calls), 0, 'provision: ...before the daemon is asked');
	e = mkenv({});
	e.files['/tmp/b.json'] = BUNDLE;
	e.uci = { m1: { '.type': 'interface' } };
	eq(ctl.provision(e.ctx, 'm1', [ '/tmp/b.json' ], e.sys), 1, 'provision: a modem without a wwand_modem section is refused');
	let n = 0;
	e = mkenv({ provision: (e) => (++n < 3) ? { ok: false, error: 'busy' } : { ok: true, ...INFO } });
	e.files['/tmp/b.json'] = BUNDLE;
	eq(ctl.provision(e.ctx, 'm1', [ '/tmp/b.json' ], e.sys), 0, 'provision: a busy card is waited for');
	eq(n, 3, 'provision: ...asking again');
	ok(index(join('', e.err), 'could not delete') < 0 && !e.files['/tmp/b.json'], 'provision: a bundle the assistant left is deleted here');
	e = mkenv({ provision: { ok: false, error: 'ipa_not_installed', detail: '/usr/lib/wwand/ipad is missing' } });
	e.files['/tmp/b.json'] = BUNDLE;
	eq(ctl.provision(e.ctx, 'm1', [ '/tmp/b.json' ], e.sys), 3, 'provision: no assistant installed is exit 3 (unsupported)');
}

{
	// poll: waits out a running scheduled run, starts its own, waits for the end
	let st = { ok: true, enabled: true, state: 'running', runs: 4, backend: 'emulated', bind: 'pending', eid: 'E1' };
	let e = mkenv({
		status: (e) => {
			// the scheduled run ends after 3 s; ours after another 5
			if (st.state == 'running' && st.runs == 4 && e.clock >= 1003)
				st = { ...st, state: 'idle', runs: 5 };
			else if (st.state == 'running' && st.runs == 5 && e.clock >= 1010)
				st = { ...st, state: 'idle', runs: 6, bind: 'done',
				       last_poll: { at: e.clock, ok: true, summary: { code: 0, packages: 2, acknowledged: 2, notifications: 1 } } };

			return st;
		},
		poll: (e) => { st = { ...st, state: 'running' }; return { ok: true, started: true }; },
	});
	eq(ctl.poll_wait(e.ctx, 'm1', [], e.sys), 0, 'poll: exit 0 after a completed run');
	eq(e.json(), { result: 'ok', packages: 2, results: 2, notifications: 1, bound: true, bind: 'done', eid: 'E1', error: null },
	   'poll: the JSON line: packages, acknowledged results, bound');
	eq(length(filter(e.calls, (c) => c[1] == 'poll')), 1, 'poll: started once, after the running one ended');

	// the eIM refused the binding: exit 2
	st = { ok: true, enabled: true, state: 'idle', runs: 0, backend: 'emulated', bind: 'pending', eid: 'E1' };
	e = mkenv({
		status: (e) => st,
		poll: (e) => {
			st = { ...st, runs: 1, bind: 'refused', last_poll: { at: 1, ok: false,
				error: 'the eIM refused the binding (403): not polling until an operator acts',
				summary: { code: 4, bind: 'refused' } } };
			return { ok: true, started: true };
		},
	});
	eq(ctl.poll_wait(e.ctx, 'm1', [], e.sys), 2, 'poll: a 403 at binding is exit 2');
	eq(e.json().bound, false, 'poll: ...not bound');
	ok(index(e.json().error, '403') >= 0, 'poll: ...and why');

	// an eIM that is not reachable: exit 1 with the assistant's reason
	st = { ok: true, enabled: true, state: 'idle', runs: 0, backend: 'emulated', bind: 'done' };
	e = mkenv({
		status: (e) => st,
		poll: (e) => {
			st = { ...st, runs: 1, last_poll: { ok: false, error: 'eIM https://eim/gsma/rsp2/asn1: connect failed',
			                                   summary: { code: 1 } } };
			return { ok: true };
		},
	});
	eq(ctl.poll_wait(e.ctx, 'm1', [], e.sys), 1, 'poll: a transport error is exit 1');
	eq(e.json().error, 'eIM https://eim/gsma/rsp2/asn1: connect failed', 'poll: ...with the reason');

	// bounded: a run that does not end
	st = { ok: true, enabled: true, state: 'idle', runs: 0 };
	e = mkenv({ status: (e) => st, poll: (e) => { st = { ...st, state: 'running' }; return { ok: true }; } });
	eq(ctl.poll_wait(e.ctx, 'm1', [ '--timeout', '30' ], e.sys), 1, 'poll: bounded by --timeout');
	ok(e.clock <= 1032 && index(e.json().error, 'timeout') == 0, 'poll: ...and says so');

	// fleet management off, no assistant
	e = mkenv({ status: { ok: true, enabled: false } });
	eq(ctl.poll_wait(e.ctx, 'm1', [], e.sys), 1, 'poll: option ipa off is a failure, said');
	e = mkenv({ status: { ok: true, enabled: true, state: 'idle', runs: 0 },
	            poll: { ok: false, error: 'esim_not_installed' } });
	eq(ctl.poll_wait(e.ctx, 'm1', [], e.sys), 3, 'poll: no wwand-esim is exit 3');
}

{
	let e = mkenv({ info: { ok: true, ...INFO, bind: 'done', bound: true, counter: 3, last_poll: 1234, last_error: null } });
	eq(ctl.info(e.ctx, 'm1', e.sys), 0, 'info: exit 0');
	eq(e.json(), { eid: 'E1', card_type: 'emulated', bound: true, bind: 'done', counter: 3, key_fingerprint: 'AB12',
	               last_poll: 1234, last_error: null }, 'info: the fields the lab driver reads');

	e = mkenv({ reset: { ok: true, reset: true } });
	e.uci.m1.ipa = '1';
	eq(ctl.reset(e.ctx, 'm1', e.sys), 0, 'reset: exit 0');
	eq(e.json(), { result: 'ok' }, 'reset: the JSON line');
	eq(e.calls[0], [ 'modem_plugin', 'reset', { all: false } ], 'reset: of this card only, by default');
	ok(index(join('', e.err), 'no_eim_config') >= 0, 'reset: says that polls fail until a new bundle comes');
	e = mkenv({ reset: { ok: false, error: 'busy' } });
	eq(ctl.reset(e.ctx, 'm1', e.sys), 1, 'reset: a card that stays busy is a failure');
	e = mkenv({ reset: { ok: true, reset: true, all: true } });
	eq(ctl.reset(e.ctx, 'm1', e.sys, true), 0, 'reset --all: exit 0');
	eq(e.calls[0], [ 'modem_plugin', 'reset', { all: true } ], 'reset --all: asks the plugin for every card');
	ok(index(join('', e.err), 'device key') >= 0, 'reset --all: says the device key went too');
}

done('test_ctl_ipa');

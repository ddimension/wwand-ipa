// wwand tests — ipa.uc, the eIM poll scheduler (wwand-ipa), and the simops
// side of it: the eSIM lock on an eIM-managed card and the connection token.
//
// The assistant itself is a C program (feed: wwand-ipad) with its own tests;
// here the bridge is a fake that records the command line and plays the
// assistant's side of the stdio protocol.

'use strict';

import * as uloop from 'uloop';
import { eq, ok, done } from './lib/check.uc';

let ipa = require('wwand.plugins.ipa');

// --- pure helpers -------------------------------------------------------------

eq(ipa.imei_of('351234567890123'), '351234567890123', 'imei: a well-formed IMEI is passed on');
eq(ipa.imei_of('35123'), null, 'imei: a short one is not');
eq(ipa.imei_of('3512345678901x3'), null, 'imei: nor one that is not all digits');
eq(ipa.imei_of(null), null, 'imei: no IMEI, none');

eq(ipa.interval_of({}), 3600, 'interval: default 3600 s');
eq(ipa.interval_of({ ipa_interval: 60 }), 300, 'interval: floored at 300 s');
eq(ipa.interval_of({ ipa_interval: 7200 }), 7200, 'interval: taken as set');

let T = { settle: 60, retry: 600 };

eq(ipa.due({}, {}, T), null, 'due: never while offline');
eq(ipa.due({ online_since: 1000 }, {}, T), 1060, 'due: first run after the settle time');
eq(ipa.due({ online_since: 1000, last_end: 2000, last_ok: true }, {}, T), 5600,
	'due: after a good run, the interval');
eq(ipa.due({ online_since: 1000, last_end: 2000, last_ok: false }, {}, T), 2600,
	'due: after a failed run, the shorter retry');
eq(ipa.due({ online_since: 1000, last_end: 2000, last_ok: false }, { ipa_interval: 300 }, T), 2300,
	'due: the retry never exceeds the interval');

// the fleet spread: fixed per device, different between devices
let sa = ipa.spread_of('351234567890123'), sb = ipa.spread_of('351234567890124');
ok(sa >= 0 && sa < 1 && sb >= 0 && sb < 1, 'spread: a fraction in [0, 1)');
eq(ipa.spread_of('351234567890123'), sa, 'spread: the same device always gets the same one');
ok(sa != sb, 'spread: neighbouring IMEIs do not');
eq(ipa.spread_of(null), 0, 'spread: none without an IMEI');

let T2 = { settle: 60, settle_spread: 300, retry: 600 };
eq(ipa.due({ online_since: 1000, spread: 0.5 }, {}, T2), 1210,
	'due: the first run waits the settle time plus its share of the spread');
eq(ipa.due({ online_since: 1000, last_end: 2000, last_ok: true, spread: 0.5 }, {}, T2), 5780,
	'due: a good run adds up to a tenth of the interval, per device');
eq(ipa.due({ online_since: 1000, last_end: 2000, last_ok: false, fails: 2 }, {}, T2), 3200,
	'due: the retry doubles with each consecutive failure');
eq(ipa.due({ online_since: 1000, last_end: 2000, last_ok: false, fails: 3 }, {}, T2), 4400,
	'due: and again');
eq(ipa.due({ online_since: 1000, last_end: 2000, last_ok: false, fails: 9 }, {}, T2), 5600,
	'due: but never beyond the interval');

eq(ipa.build_cmd({ ipad: '/x/ipad', dir: '/s' }),
	"/x/ipad -s '/s' poll 2>&1",
	'cmd: the state directory and the poll; stderr into the pipe');
eq(ipa.build_cmd({ ipad: '/x/ipad', dir: '/s', backend: 'emu', eim_id: 'eim.example', insecure: true,
                   imei: '351234567890123', direct: true, cmd: 'provision', file: '/etc/e.ber' }),
	"/x/ipad -s '/s' -b emu -e 'eim.example' -k -i 351234567890123 -D provision '/etc/e.ber' 2>&1",
	'cmd: backend, eIM id, insecure, IMEI, direct download and a file argument');
eq(ipa.build_cmd({ ipad: '/x/ipad', dir: '/s', backend: 'auto' }), "/x/ipad -s '/s' poll 2>&1",
	'cmd: auto is the assistant\'s default, not passed');
eq(ipa.log_level('ipad: -r wants 6 hex digits'), 'notice', 'log: what reaches the pipe is worth seeing');

// --- the scheduler against a fake bridge ---------------------------------------

const EID = '89049032123451234512345678901235';

let clock = 1000;
let files = {};
let online = null;           // the connection token the fake daemon reports
let runs = [];               // command lines ipa_run was given
let resets = 0;
let reset_res = {};          // what apply_sim_reset answers
let modem_resets = [];
let logs = [];
let script = null;           // what the fake assistant does in a run
let refreshes = [];          // profile-list re-reads the scheduler asked for
let card_after = null;       // the profile list a re-read finds

// the assistant as the fake plays it by default: says what card it found,
// then exits 3 while the card has no eIM (ipad main.c EXIT_NO_EIM), stores
// one on `provision`, and polls fine once it has one
let provisioned = false;
let fake_ipad = (cmd, on_ipa, on_done) => {
	on_ipa({ kind: 'event', event: 'info', payload: { eid: EID, backend: 'emulated', key_fingerprint: 'AB12' } }, () => {
		if (index(cmd, ' provision ') >= 0) {
			provisioned = true;
			return on_done(null, '');
		}

		on_done(provisioned ? null : { error: 'lpac', code: 3 }, '');
	});
	return null;
};

let bridge = {
	session_run: (ref, slot, label, cmd, log_level, on_ipa, on_done) => {
		push(runs, cmd);
		return script ? script(on_ipa, on_done, cmd) : fake_ipad(cmd, on_ipa, on_done);
	},
	apply_sim_reset: (ref, slot, cb) => { resets++; cb(null, reset_res); },
};

let modem = { info: { imei: '351234567890123' } };

let mk = (over) => ipa.scheduler({
	bridge: bridge,
	log: (lvl, msg) => push(logs, msg),
	modem_of: (ref) => (ref == 'm1') ? { modem: modem } : null,
	online: () => online,
	ipad_path: '/x/ipad', state_dir: '/s',
	// no first-run spread here, and the clock below steps 4000 s at a time,
	// past the interval plus its largest per-device stretch (3600 + 360)
	timing: { settle: 60, settle_spread: 0, retry: 600, online_timeout: 1, online_poll: 0.01 },
	now: () => clock,
	exists: (p) => p == '/x/ipad' || !!files[p],
	modem_reset: (ref, cb) => { push(modem_resets, ref); cb(null, {}); },
	refresh: (ref, eid, slot, cb) => {
		push(refreshes, [ ref, eid, slot ]);

		if (card_after != null)
			cb(map(card_after, (i) => ({ iccid: i })));
	},
	...(over ?? {}),
});

let s = mk();
let on = { ipa: true };

s.tick('m1', { ipa: false });
eq(length(runs), 0, 'tick: nothing without option ipa');

s.tick('m1', on);
eq(length(runs), 0, 'tick: nothing while offline');

online = 'wan:1';
s.tick('m1', on);
eq(length(runs), 0, 'tick: online, but not settled yet');

clock += 60;
s.tick('m1', on);
eq(s.status('m1', on).last_error, 'no_eim_config',
	'first run: the card has no eIM and none is configured: refused, not guessed');
eq(length(runs), 1, 'first run: the assistant was asked (it knows whether the card has an eIM)');
eq(s.status('m1', on).eid, EID, 'first run: the card it reported is in status');
eq(s.status('m1', on).backend, 'emulated', 'first run: ...and how it drives it');
eq(s.status('m1', on).key_fingerprint, 'AB12', 'first run: ...and the device key the eIM must know');

// provisioning: the configured eIM file exists, the card has none yet
files['/etc/wwand/eim.ber'] = true;
let cfg = { ipa: true, ipa_eim_config: '/etc/wwand/eim.ber' };
runs = [];
clock += 600;
s.tick('m1', cfg);
eq(length(runs), 3, 'provision: the poll says no eIM, provision stores it, a second poll uses it');
ok(index(runs[1], "provision '/etc/wwand/eim.ber'") >= 0, 'provision: the second run stores the file');
ok(index(runs[0], ' poll ') >= 0 && index(runs[2], ' poll ') >= 0, 'provision: the others poll');
ok(index(runs[0], "-s '/s'") >= 0, 'provision: the state directory is passed');
ok(index(runs[0], '-i 351234567890123') >= 0, 'provision: the modem\'s IMEI for DeviceInfo');
ok(index(runs[0], ' -D ') >= 0, 'provision: direct download offered by default');
eq(s.status('m1', cfg).last_ok, true, 'provision: the run counts as good');

eq(refreshes[length(refreshes) - 1], [ 'm1', EID, 1 ], 'refresh: the profile list is read again after a run that reached the card');

// the card has its eIM now: a later run only polls
runs = [];
clock += 4000;
s.tick('m1', cfg);
eq(length(runs), 1, 'poll: a known card is polled directly');

// an eIM id that could break out of the command line is refused
runs = [];
clock += 4000;
s.tick('m1', { ipa: true, ipa_eim_id: "x'; reboot; '" });
eq(length(runs), 0, 'safety: an eIM id with shell characters never reaches the shell');
eq(s.status('m1', cfg).state, 'idle', 'safety: and the scheduler is not left busy');

// a failed run: the assistant exits non-zero
script = (on_ipa, on_done) => { on_done({ error: 'lpac', code: 234 }, ''); return null; };
runs = [];
clock += 4000;
s.tick('m1', cfg);
eq(s.status('m1', cfg).last_error, 'exit 234', 'failure: the exit status is reported');
eq(s.status('m1', cfg).next_due, clock + 600, 'failure: retried after the retry time');

// busy: the bridge refuses (an lpac operation holds the card)
script = (on_ipa, on_done) => ({ error: 'busy' });
clock += 600;
s.tick('m1', cfg);
eq(s.status('m1', cfg).last_error, 'busy', 'busy: a refused start is a failed run, not a stuck one');
eq(s.status('m1', cfg).state, 'idle', 'busy: the scheduler is free again');
refreshes = [];
clock += 4000;
s.tick('m1', cfg);
eq(refreshes, [], 'refresh: not after a run that never reached the card');

// --- a profile change: reset the SIM, wait for a NEW connection ---------------

let answers = [];

script = (on_ipa, on_done) => {
	on_ipa({ kind: 'ipa', event: 'profile_changed' }, (obj) => {
		push(answers, obj);
		on_done(null, '');
	});
	return null;
};

online = 'wan:1';
resets = 0;
clock += 4000;
s.tick('m1', cfg);
eq(resets, 1, 'profile change: the SIM is reset so the modem takes the new profile');
eq(s.status('m1', cfg).state, 'waiting_online', 'profile change: waiting for the connection');

// the old session is still CONNECTED: that must not count as "back"
uloop.init();
uloop.timer(50, () => {
	eq(length(answers), 0, 'profile change: the still-connected old session is not the answer');
	online = 'wan:2';   // the daemon brought up a new session
});
uloop.timer(150, () => uloop.end());
uloop.run();

eq(answers, [ { online: true } ], 'profile change: a new connection generation is');
eq(s.status('m1', cfg).profile_changes, 1, 'profile change: counted');
eq(s.status('m1', cfg).state, 'idle', 'profile change: the run completed');

// the connection never comes back: the assistant is told so (it rolls back)
answers = [];
online = 'wan:2';
clock += 4000;
s.tick('m1', cfg);
online = null;
let t0 = clock;
uloop.init();
uloop.timer(30, () => { clock = t0 + 2; });   // past online_timeout
uloop.timer(150, () => uloop.end());
uloop.run();
eq(answers, [ { online: false } ], 'profile change: no connection by the deadline is reported as such');

// still the OLD session at the deadline: not back either
answers = [];
online = 'wan:2';
clock += 4000;
s.tick('m1', cfg);
t0 = clock;
uloop.init();
uloop.timer(30, () => { clock = t0 + 2; });
uloop.timer(150, () => uloop.end());
uloop.run();
eq(answers, [ { online: false } ], 'profile change: the pre-reset session at the deadline is not "back"');

// the assistant dies while we wait: the pending check must not revive the run
let died = null;
script = (on_ipa, on_done) => {
	on_ipa({ kind: 'ipa', event: 'profile_changed' }, (obj) => push(answers, obj));
	died = on_done;
	return null;
};
answers = [];
clock += 4000;
s.tick('m1', cfg);
died({ error: 'timeout', code: -1 }, '');
eq(s.status('m1', cfg).state, 'idle', 'dead run: idle at once');
online = 'wan:3';   // a new session arrives after the run is already over
uloop.init();
uloop.timer(150, () => uloop.end());
uloop.run();
eq(s.status('m1', cfg).state, 'idle', 'dead run: a late check does not put it back to running');
eq(answers, [], 'dead run: and nothing is answered to a process that is gone');

// --- what a run did to the card ------------------------------------------------

// a switch A -> B, reported with the ICCIDs the modem read before and after
// the SIM reset; the list comparison finds C installed and D deleted
modem.info.iccid = 'A';
modem.esim_info = { profiles: [ { iccid: 'A' }, { iccid: 'B' }, { iccid: 'D' } ] };
card_after = [ 'A', 'B', 'C' ];
script = (on_ipa, on_done) => {
	on_ipa({ kind: 'ipa', event: 'profile_changed' }, (obj) => on_done(null, ''));
	return null;
};
online = 'wan:5';
clock += 4000;
s.tick('m1', cfg);
modem.info.iccid = 'B';   // the re-read after the SIM reset
uloop.init();
uloop.timer(20, () => { online = 'wan:6'; });
uloop.timer(150, () => uloop.end());
uloop.run();
eq(s.status('m1', cfg).last_changes,
	{ switched: [ { from: 'A', to: 'B', rollback: false } ], installed: [ 'C' ], deleted: [ 'D' ], downloads: [] },
	'changes: the switch, and what the list comparison found installed and deleted');

// the eIM stays unreachable on B: the assistant rolls back to A in the same run
modem.esim_info = { profiles: [ { iccid: 'A' }, { iccid: 'B' } ] };
card_after = [ 'A', 'B' ];
let step_no = 0;
script = (on_ipa, on_done) => {
	let next;
	next = () => on_ipa({ kind: 'ipa', event: 'profile_changed' }, () => {
		if (++step_no < 2) {
			next();
			modem.info.iccid = 'A';   // the rollback's SIM reset re-reads A
			uloop.timer(20, () => { online = 'wan:11'; });
			return;
		}
		on_done(null, '');
	});
	next();
	return null;
};
modem.info.iccid = 'A';
online = 'wan:9';
clock += 4000;
s.tick('m1', cfg);
modem.info.iccid = 'B';
uloop.init();
uloop.timer(20, () => { online = 'wan:10'; });
uloop.timer(300, () => uloop.end());
uloop.run();
eq(s.status('m1', cfg).last_changes?.switched,
	[ { from: 'A', to: 'B', rollback: false }, { from: 'B', to: 'A', rollback: true } ],
	'changes: a switch back to where the run started is the rollback');
eq(s.status('m1', cfg).last_changes?.installed, [], 'changes: nothing installed');

// no list from before: no installed/deleted claims
modem.esim_info = null;
card_after = [ 'A', 'B' ];
script = null;
clock += 4000;
s.tick('m1', cfg);
eq(s.status('m1', cfg).last_changes, { switched: [], installed: null, deleted: null, downloads: [] },
	'changes: without a list from before, nothing is claimed installed');

// the SIM power cycle fails: the modem is reset instead, and the new ICCID is
// read from the modem object the reset creates, not the one from the event
reset_res = { apply: 'modem_reset' };
modem_resets = [];
modem.info.iccid = 'A';
script = (on_ipa, on_done) => {
	on_ipa({ kind: 'ipa', event: 'profile_changed' }, (obj) => on_done(null, ''));
	return null;
};
online = 'wan:20';
clock += 4000;
s.tick('m1', cfg);
eq(modem_resets, [ 'm1' ], 'reset fallback: no SIM power cycle, so the modem is reset — nobody else would');
modem = { info: { imei: '351234567890123', iccid: 'B' } };   // the object after the reset
uloop.init();
uloop.timer(20, () => { online = 'wan:21'; });
uloop.timer(150, () => uloop.end());
uloop.run();
eq(s.status('m1', cfg).last_changes?.switched, [ { from: 'A', to: 'B', rollback: false } ],
	'reset fallback: the new ICCID comes from the modem that exists now');
reset_res = {};

// a dual-SIM module whose eUICC is the active card in physical slot 2: that
// is the card managed, whatever sim_slot says
modem.slot_status = (cb) => cb(null, [ { physical: 1, is_euicc: false, active: false },
                                       { physical: 2, is_euicc: true, active: true } ]);
script = null;
refreshes = [];
clock += 4000;
s.tick('m1', cfg);
eq(refreshes[0]?.[2], 2, 'slot: the active eUICC\'s physical slot, not the configured one');
delete modem.slot_status;

// --- connectivity, download, export --------------------------------------------

{
	let ups = [], dls = [], nts = [], replies = [];
	let dl_err = null, nt_err = null;
	let s2 = mk({
		sim_upsert: (iccid, fields, origin, opts) => {
			push(ups, [ iccid, fields, origin, opts ]);
			return { written: true, section: 'wwsim_' + iccid };
		},
		download: (ref, code, cc, cb) => { push(dls, [ ref, code, cc ]); cb(dl_err); },
		notify: (ref, seq, cb) => { push(nts, [ ref, seq ]); cb(nt_err); },
	});
	let ev = (event, payload) => (on_ipa, on_done) => {
		on_ipa({ kind: 'event', event: event, payload: payload }, (obj) => {
			push(replies, obj);
			on_done(null, '');
		});
		return null;
	};

	provisioned = true;
	online = 'wan:40';

	// an IoT eUICC states its parameters: written, kept current
	script = ev('connectivity', { iccid: '89000123456789012342', emulated: false, source: 'card',
		apn: 'iot.example', username: 'u', password: 'p', pdp_type: 'ipv4' });
	s2.poll('m1', cfg, () => null);
	eq(ups, [ [ '89000123456789012342', { apn: 'iot.example', pdp_type: 'ipv4', username: 'u', password: 'p', auth: 'both' },
	            'ipa', { create_only: false } ] ],
		'connectivity: the card\'s parameters go to sim_upsert, credentials with auth both');
	eq(replies, [ {} ], 'connectivity: answered');
	eq(s2.status('m1', cfg).connectivity,
		{ iccid: '89000123456789012342', source: 'card', apn: 'iot.example', pdp_type: 'ipv4',
		  section: 'wwsim_89000123456789012342', written: true, reason: null },
		'connectivity: status says what was written where (the password is not in it)');

	// an emulated SGP.22 card has none: the section is only created, never emptied
	ups = [];
	script = ev('connectivity', { iccid: '89000123456789012342', emulated: true, source: 'none' });
	s2.poll('m1', cfg, () => null);
	eq(ups, [ [ '89000123456789012342', {}, 'ipa', { create_only: true } ] ],
		'connectivity: nothing stated, nothing but the section, and only when there is none');
	eq(s2.status('m1', cfg).connectivity.source, 'emulated: none', 'connectivity: the source says why the APN is empty');

	// a malformed ICCID never reaches the writer
	ups = [];
	script = ev('connectivity', { iccid: '8900; reboot', source: 'card', apn: 'x' });
	s2.poll('m1', cfg, () => null);
	eq(ups, [], 'connectivity: an ICCID that is not one is not written');

	// a direct download goes to lpac through the bridge
	replies = [];
	script = ev('download', { activation_code: '1$smdp.example$MATCH' });
	s2.poll('m1', cfg, () => null);
	eq(dls, [ [ 'm1', '1$smdp.example$MATCH', null ] ], 'download: the activation code reaches the bridge');
	eq(replies, [ { ok: true } ], 'download: success is reported back');
	eq(s2.status('m1', cfg).last_changes.downloads, [ { ok: true } ], 'download: and recorded');
	ok(index(join(' ', logs), 'MATCH') < 0, 'download: the activation code is not logged');

	dl_err = { error: 'download_failed' };
	replies = [];
	s2.poll('m1', cfg, () => null);
	eq(replies, [ { ok: false, error: 'download_failed' } ], 'download: a failure too');
	dl_err = null;

	// the download's PIR goes to the SM-DP+ through the bridge (SGP.32 3.2.3.1
	// step 14), with the sequence number the assistant names
	replies = [];
	script = ev('notify', { seq: 7 });
	s2.poll('m1', cfg, () => null);
	eq(nts, [ [ 'm1', 7 ] ], 'notify: the sequence number reaches the bridge');
	eq(replies, [ { ok: true } ], 'notify: delivery is reported back');

	nt_err = { error: 'notify_failed' };
	replies = [];
	s2.poll('m1', cfg, () => null);
	eq(replies, [ { ok: false, error: 'notify_failed' } ], 'notify: and a failure, so the assistant keeps it');
	nt_err = null;

	// export: its own run with the file argument
	runs = [];
	script = null;
	let eres = null;
	s2.export('m1', cfg, '/tmp/wwand/dev.json', (e, r) => { eres = [ e, r ]; });
	ok(index(runs[0] ?? '', " export '/tmp/wwand/dev.json'") >= 0, 'export: ipad export with the file');
	eq(eres, [ null, { file: '/tmp/wwand/dev.json' } ], 'export: answers with the file');
	s2.export('m1', cfg, "/tmp/x'; reboot", (e, r) => { eres = [ e, r ]; });
	eq(eres[0]?.error, 'invalid_argument', 'export: a path with shell characters is refused');
	script = null;
}

// --- the bundle (eIM decision D-69): provision, info, reset, the summary ------

{
	let resets_run = [];
	let s3 = mk({ reset_run: (cmd) => { push(resets_run, cmd); return 0; } });
	let ev = (evs, code) => (on_ipa, on_done) => {
		let i = 0, next;

		next = () => (i < length(evs))
			? on_ipa({ kind: 'event', event: evs[i][0], payload: evs[i++][1] }, next)
			: on_done(code ? { error: 'lpac', code: code } : null, '');
		next();
		return null;
	};
	let info_ev = [ 'info', { eid: EID, backend: 'emulated', key_fingerprint: 'AB12', bind: 'pending', counter: 0 } ];

	provisioned = true;
	online = 'wan:50';

	// provision: its own run with the file; answers the card's info
	runs = [];
	script = ev([ info_ev, [ 'summary', { command: 'provision', code: 0, bind: 'pending' } ] ]);
	let before = s3.status('m1', cfg);
	let pres = null;
	s3.provision('m1', cfg, '/tmp/b.json', (e, r) => { pres = [ e, r ]; });
	ok(index(runs[0] ?? '', " provision '/tmp/b.json'") >= 0, 'bundle: ipad provision with the file');
	eq(pres, [ null, { eid: EID, card_type: 'emulated', bind: 'pending', bound: false, counter: 0, key_fingerprint: 'AB12',
	                   last_poll: null, last_ok: null, last_error: null, file: '/tmp/b.json' } ],
		'bundle: provision answers the card, binding pending');
	eq([ s3.status('m1', cfg).runs, s3.status('m1', cfg).last_end ], [ before.runs, before.last_end ],
		'bundle: a provision is no poll: the schedule does not move');
	s3.provision('m1', cfg, "/tmp/b'.json", (e, r) => { pres = [ e, r ]; });
	eq(pres[0]?.error, 'invalid_argument', 'bundle: a path with shell characters is refused');

	// a poll: the summary event is the run's account, the bind state follows it
	script = ev([ info_ev, [ 'summary', { command: 'poll', code: 0, packages: 1, acknowledged: 1, bind: 'done' } ] ]);
	s3.poll('m1', cfg, () => null);
	let st = s3.status('m1', cfg);
	eq([ st.bind, st.last_poll.ok, st.last_poll.summary.packages ], [ 'done', true, 1 ], 'bundle: poll: bound, the summary kept');

	// refused (ipad exit 4): the assistant's reason, not "exit 4"
	script = ev([ info_ev, [ 'summary', { command: 'poll', code: 4, bind: 'refused',
		error: 'the eIM refused the binding (403): not polling until an operator acts' } ] ], 4);
	s3.poll('m1', cfg, () => null);
	st = s3.status('m1', cfg);
	eq([ st.bind, st.last_poll.ok, st.last_poll.summary.code ], [ 'refused', false, 4 ], 'bundle: poll refused: code 4 kept');
	ok(index(st.last_error, '403') >= 0, 'bundle: poll refused: the assistant\'s reason is the error');

	// info: a run of its own, not a poll
	let before_runs = st.runs;
	script = ev([ [ 'info', { eid: EID, backend: 'emulated', key_fingerprint: 'AB12', bind: 'refused', counter: 0 } ] ]);
	let ires = null;
	s3.info('m1', cfg, (e, r) => { ires = [ e, r ]; });
	eq(ires[1]?.bound, false, 'bundle: info: not bound');
	eq(ires[1]?.bind, 'refused', 'bundle: info: refused');
	ok(index(ires[1]?.last_error ?? '', '403') >= 0, 'bundle: info: the last poll\'s error');
	eq(s3.status('m1', cfg).runs, before_runs, 'bundle: info is no poll either');

	// reset: without a card session, forgets what the plugin knew of the card
	runs = [];
	let rr = null;
	s3.reset('m1', cfg, (e, r) => { rr = [ e, r ]; });
	eq(rr, [ null, { reset: true, all: false } ], 'bundle: reset done');
	eq(resets_run, [ sprintf("/x/ipad -s '/s' reset %s >/dev/null 2>&1", EID) ],
		'bundle: reset runs ipad reset of THIS card only: the directory is shared with the other modems');
	eq(length(runs), 0, 'bundle: reset needs no card session when the EID is known');
	st = s3.status('m1', cfg);
	eq([ st.eid, st.bind, st.key_fingerprint, st.last_poll ], [ null, null, null, null ], 'bundle: reset: the card is forgotten');

	// the EID not known (forgotten just now): an info run reads it first
	resets_run = [];
	script = ev([ info_ev ]);
	s3.reset('m1', cfg, (e, r) => { rr = [ e, r ]; });
	eq(length(runs), 1, 'bundle: reset without a known EID: an info run first');
	eq(resets_run, [ sprintf("/x/ipad -s '/s' reset %s >/dev/null 2>&1", EID) ], 'bundle: then the reset of the card it read');
	eq(rr, [ null, { reset: true, all: false } ], 'bundle: reset after info done');

	// --all: every card, the device key and the binding
	resets_run = [];
	runs = [];
	s3.reset('m1', cfg, (e, r) => { rr = [ e, r ]; }, { all: true });
	eq(resets_run, [ "/x/ipad -s '/s' reset all >/dev/null 2>&1" ], 'bundle: reset --all runs ipad reset all');
	eq([ rr, length(runs) ], [ [ null, { reset: true, all: true } ], 0 ], 'bundle: reset --all needs no card and no EID');

	// reset while a run holds the state: refused
	script = (on_ipa, on_done) => { on_ipa({ kind: 'event', event: 'info', payload: {} }, () => null); return null; };
	s3.poll('m1', cfg, () => null);
	s3.reset('m1', cfg, (e, r) => { rr = [ e, r ]; });
	eq(rr[0]?.error, 'busy', 'bundle: no reset under a running assistant');
	// --all from another modem: it would pull the directory from under the run
	rr = null;
	s3.reset('m2', cfg, (e, r) => { rr = [ e, r ]; }, { all: true });
	eq(rr[0]?.error, 'busy', 'bundle: no reset --all while any modem runs');
	script = null;
}

// --- the real bridge: the assistant's log reaches the syslog, not a file ------

import * as fs from 'fs';

let bridge_mod = require('wwand.esim_bridge');
let tmp = getenv('TMPDIR') ?? '/tmp';
let stub = sprintf('%s/wwand-test-ipad.sh', tmp);
let sf = fs.open(stub, 'w');
sf.write("#!/bin/sh\n" +
	"echo 'ipad: usage trouble' >&2\n" +
	"echo '{\"type\":\"event\",\"payload\":{\"event\":\"connectivity\",\"iccid\":\"8949\",\"apn\":\"iot.ex\\\\\"q\"}}'\n" +
	"read line\n" +
	"echo \"host said $line\" >&2\n" +
	"exit 3\n");
sf.close();

try { fs.mkdir('/tmp/wwand'); } catch (e) { }
fs.writefile('/tmp/wwand/esim-download.log', 'lpac run\n');

let seen = [];
let br = bridge_mod.create({ esim: {}, log: (lvl, msg) => push(seen, [ lvl, msg ]),
	modem_of: (r) => ({ modem: { id: r, _esim_op: 0 } }) });
let rres = null;

uloop.init();
let got_payload = null;
let started = br.session_run('m0', 1, 'ipa', sprintf('sh %s 2>&1', stub), ipa.log_level,
	(rec, reply) => { got_payload = rec.payload; reply({ online: true }); },
	(err, out) => { rres = { err, out }; uloop.end(); });
uloop.timer(5000, () => uloop.end());
uloop.run();

eq(started, null, 'bridge: the run starts');
eq(rres?.err?.code, 3, 'bridge: the exit status is the verdict');
eq(rres?.out, '', 'bridge: no log file to hand back');
let lvl_of = (needle) => {
	for (let e in seen)
		if (index(e[1], needle) >= 0)
			return e[0];
	return null;
};
eq(lvl_of('usage trouble'), 'notice', 'bridge: what ipad writes to stderr reaches the syslog');
// the script holds iot.ex\\"q; dash's echo halves the backslash pair, so the
// line carries the JSON string iot.ex\"q, a quote in the value
eq(got_payload?.apn, 'iot.ex"q', 'bridge: the event payload reaches the plugin, escapes undone');
eq(got_payload?.iccid, '8949', 'bridge: ...every field of it');
ok(lvl_of('host said {"type":"event","payload":{ "online": true }}') != null,
	'bridge: the answer went back to the process');
eq(fs.readfile('/tmp/wwand/esim-download.log'), 'lpac run\n', 'bridge: lpac\'s log file is left alone');
fs.unlink(stub);

// --- the plugin wwand loads (plugins.uc) ------------------------------------------

eq(ipa.name, 'ipa', 'plugin: its name');
eq(ipa.options, [ 'ipa', 'ipa_interval', 'ipa_eim_config', 'ipa_eim_id', 'ipa_insecure', 'ipa_backend', 'ipa_direct' ],
	'plugin: the options wwand hands over');
eq(ipa.cfg_of({ ipa: '1', ipa_interval: '900', ipa_eim_config: '/e.ber', ipa_eim_id: '', ipa_insecure: '0' },
              { cfg: { sim_slot: 2 } }),
	{ ipa: true, ipa_interval: 900, ipa_eim_config: '/e.ber', ipa_eim_id: null, ipa_insecure: false,
	  ipa_backend: 'auto', ipa_direct: true, sim_slot: 2 },
	'plugin: raw uci values become typed, empty is unset, sim_slot from the modem');
eq(ipa.cfg_of({ ipa_backend: 'emu', ipa_direct: '0' }).ipa_backend, 'emu', 'plugin: backend emu');
eq(ipa.cfg_of({ ipa_backend: 'emu', ipa_direct: '0' }).ipa_direct, false, 'plugin: direct download off');
eq(ipa.cfg_of({ ipa_backend: 'x; reboot' }).ipa_backend, 'auto', 'plugin: an unknown backend is auto');
eq(ipa.cfg_of({ ipa_interval: 'soon' }).ipa_interval, null, 'plugin: an interval that is no number is unset');

let bridge_on = true;
let pd = {
	log: () => null,
	modem_of: (ref) => ({ modem: { info: {} }, cfg: {} }),
	connection_token: () => null,
	modem_reset: () => null,
	esim: () => null,
	esim_bridge: () => bridge_on ? {} : null,
	esim_refresh: () => null,
};
let pl = ipa.create(pd);

eq(pl.esim_guard('m0', 'enable', { ipa: '1' }), { reason: 'this card is managed by an eIM (option ipa)' },
	'plugin: a card with option ipa is locked');
eq(pl.esim_guard('m0', 'enable', {}), null, 'plugin: one without is not');
bridge_on = false;
eq(pl.esim_guard('m0', 'enable', { ipa: '1' }), null,
	'plugin: without wwand-esim nothing runs, so nothing is locked');
bridge_on = true;
eq(pl.read_ops, [ 'status' ], 'plugin: status is the read-only op');

let pres = null;
pl.ops.poll('m0', {}, {}, (e, r) => { pres = e; });
eq(pres?.error, 'ipa_disabled', 'plugin: a poll without option ipa is refused');
pl.ops.status('m0', { ipa: '1' }, {}, (e, r) => { pres = r; });
eq(pres?.enabled, true, 'plugin: status reads the typed options');

// THE ADAPTER THE SCHEDULER SEES (bridge_of). session_run answers null when
// the run started: an adapter that read null as "no bridge" reported every
// run as esim_not_installed while ipad ran (HW-seen on 245, 2026-09-28).
{
	let started = 0, have = true;
	let br = ipa.bridge_of({ esim_bridge: () => have ? {
		session_run: () => { started++; return null; },
		apply_sim_reset: (ref, slot, cb) => cb(null, { reset: 'sim' }),
	} : null });

	eq([ br.session_run('m0', 1, 'ipa', 'poll', 'info', () => null, () => null), started ], [ null, 1 ],
	   'adapter: a started run is no error');
	have = false;
	eq(br.session_run('m0', 1, 'ipa', 'poll')?.error, 'esim_not_installed', 'adapter: no bridge is');

	let r = null;

	br.apply_sim_reset('m0', 1, (e) => { r = e; });
	eq(r?.error, 'esim_not_installed', 'adapter: nor a SIM reset without it');
}

done('test_ipa');

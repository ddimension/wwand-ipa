#!/usr/bin/env node
/* Checks for the pure helper resources/wwand/ipafmt.js, evaluated the way
 * luci-app-wwand's tools/test-format.js evaluates format.js: as a function
 * body with the few globals LuCI provides, no DOM.
 *
 *   node luci/tools/test-ipafmt.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const src = fs.readFileSync(path.join(__dirname, '..', 'htdocs', 'luci-static', 'resources', 'wwand', 'ipafmt.js'), 'utf8')
	.replace(/^\s*'require [^']*';\s*$/gm, '');

/* LuCI's String.prototype.format, reduced to the %s and %d the helper uses */
String.prototype.format = function () {
	let args = arguments, i = 0;
	return this.replace(/%([sd%])/g, (m, c) => (c == '%') ? '%' : (c == 'd' ? String(Math.trunc(+args[i++]) || 0) : String(args[i++])));
};

const fmt = new Function('baseclass', '_', src)({ extend: (o) => o }, (s) => s);

let checks = 0, failures = 0;
function eq(got, want, label) {
	checks++;
	if (JSON.stringify(got) !== JSON.stringify(want)) {
		failures++;
		console.log(`FAIL: ${label}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`);
	}
}

eq(fmt.rows({ enabled: false }), [], 'no rows without option ipa');
eq(fmt.rows({ enabled: true, now: 1300, state: 'idle', runs: 4, profile_changes: 1,
              last_end: 1000, last_ok: false, last_error: 'exit 234', fails: 2, next_due: 2200,
              eid: 'E1', backend: 'emulated', key_fingerprint: '0123456789ABCDEF0123',
              connectivity: { iccid: '8949', source: 'emulated: none', section: 'wwsim_8949', written: true },
              last_changes: { switched: [ { from: 'A', to: 'B', rollback: false },
                                          { from: 'B', to: 'A', rollback: true } ],
                              installed: [ 'C' ], deleted: [] } }), [
	[ 'State', 'idle · 4 runs · 1 profile change' ],
	[ 'Last run', '5m 0s ago · failed: exit 234 (2 in a row)' ],
	[ 'Next poll', 'in 15m 0s' ],
	[ 'Card', 'EID E1 · SGP.22 card, emulated · device key 0123456789ABCDEF…' ],
	[ 'Connectivity', '8949: none stated (emulated: none) → wwsim_8949 (written)' ],
	[ 'Last changes', 'switched A → B · rolled back B → A · installed C' ],
], 'outcome, retry, the card, and what the last run did to it');
eq(fmt.rows({ enabled: true, now: 50, state: 'idle', runs: 0, profile_changes: 0 })[1],
   [ 'Next poll', 'once the connection is up' ], 'offline, it waits for the connection');
eq(fmt.rows({ enabled: true, now: 7500, state: 'idle', runs: 1, profile_changes: 0, last_end: 0, last_ok: true })[1],
   [ 'Last run', '2h 5m ago · ok' ], 'a good run, hours ago');

eq(fmt.rows({ enabled: true, now: 0, state: 'idle', eid: 'E2', backend: 'iot',
              connectivity: { iccid: '8949', source: 'card', apn: 'iot.ex', pdp_type: 'ipv4', section: 'mysim', reason: 'foreign' } }).slice(2), [
	[ 'Card', 'EID E2 · IoT eUICC' ],
	[ 'Connectivity', '8949: APN iot.ex · ipv4 → your wwand_sim mysim wins, not touched' ],
], 'an IoT eUICC, and a hand-written wwand_sim that wins');
eq(fmt.rows({ enabled: true, now: 0, state: 'idle', last_changes: { downloads: [ { ok: true }, { ok: false } ] } }).pop(),
   [ 'Last changes', 'downloaded · download failed' ], 'downloads the eIM asked for');

console.log(`test-ipafmt: ${checks} checks, ${failures} failures`);
process.exit(failures ? 1 : 0);

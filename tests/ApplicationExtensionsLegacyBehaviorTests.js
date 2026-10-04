#!/usr/bin/env node
// Execute the frozen page's actual root script, with finite host/transport inputs.
// This is legacy script behavior evidence, NOT native UIKit or OS-focus proof.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(process.argv[2]);
const source = fs.readFileSync(path.join(root, 'iphone.html'), 'utf8');
const scripts = [...source.matchAll(/<script[^>]*>(.*?)<\/script>/gs)].map(x => x[1]);
const program = scripts.find(x => x.startsWith('(function(){try{'));
assert(program, 'exact original root program');
const counts = JSON.parse(fs.readFileSync(path.join(root, 'api-application.json')));
const frozen = JSON.parse(fs.readFileSync(path.join(root, 'frozen-inputs.json')));
assert.equal(frozen.pages.safari.length, counts['com.apple.mobilesafari']);
assert.equal(frozen.pages.mail.length, counts['com.apple.mobilemail']);
function run(provider) {
    const writes = [], css = [], html = [], alerts = [], requests = [], storage = [];
    const dollar = selector => ({
        css: (name, value) => css.push({selector, name, value}),
        html: value => html.push({selector, value})
    });
    dollar.uri = encodeURIComponent;
    dollar.xml = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;').replaceAll('"', '&quot;');
    let callback;
    dollar.xhr = (url, method, headers, body, handlers) => {
        requests.push({url, method, headers, body});
        callback = handlers.success;
    };
    const context = {document: {write: value => writes.push(value)},
        window: {localStorage: {setItem: (key, value) => storage.push({key, value})}},
        $: dollar, alert: value => alerts.push(value)};
    if (provider !== undefined) context.cydia = provider;
    vm.runInNewContext(program, context, {timeout: 1000});
    if (callback) callback(JSON.stringify(counts)); // asynchronous completion after document.write
    return {writes, css, html, alerts, requests, storage};
}
const names = {'com.apple.mobilesafari': 'Safari',
    'com.apple.mobilemail': 'Mail & Inbox', 'example.not-in-catalog': 'Absent',
    'example.no-local-name': null};
const result = run({
    getDisplayIdentifiers: () => Object.keys(names),
    getLocalizedNameForDisplayIdentifier: id => names[id]
});
assert.equal(result.alerts.length, 0);
assert.equal(result.writes.length, 3); // unnamed applications are omitted.
assert(result.writes[0].includes('/application/example.not-in-catalog/'));
assert(result.writes[1].includes('Mail &amp; Inbox'));
assert(result.writes[2].includes('/application/com.apple.mobilesafari/'));
assert(result.writes[2].includes('cydia://application-icon/com.apple.mobilesafari'));
assert.deepEqual(result.css.map(x => x.selector), ['#app-com.apple.mobilemail', '#app-com.apple.mobilesafari']);
assert.deepEqual(result.html.map(x => x.value), [74, 139]);
assert.equal(result.requests.length, 1);
assert.equal(result.requests[0].url, '/api/application');
assert.equal(result.requests[0].method, 'POST');
assert.equal(result.requests[0].body, null); // no installed application inventory upload
assert.equal(Object.keys(result.requests[0].headers).length, 0);
assert.equal(result.storage[0].key, 'v0:badge-application');
console.log('PASS legacy root: localized sorting, unnamed omission, count filtering, icons, routes, no inventory upload');

const empty = run({getDisplayIdentifiers: () => [], getLocalizedNameForDisplayIdentifier: () => null});
assert.equal(empty.writes.length, 0);
assert.equal(empty.requests.length, 1);
assert.equal(empty.alerts.length, 0);
console.log('PASS legacy empty installed-app list');

const missingMethod = run({});
assert.equal(missingMethod.requests.length, 0);
assert.deepEqual(missingMethod.css.map(x => [x.selector,x.value]), [['#message','none'],['#error','block']]);
console.log('PASS legacy missing-capability fallback');

const missingBridge = run(undefined);
assert.equal(missingBridge.writes.length, 0);
assert.equal(missingBridge.requests.length, 0);
assert(missingBridge.alerts[0].includes('cydia'));
console.log('PASS current Safari baseline: absent bridge produces error, not a working app list');

for (const [name, bundle] of [['safari','com.apple.mobilesafari'], ['mail','com.apple.mobilemail']]) {
    const text = fs.readFileSync(path.join(root,name+'.html'),'utf8');
    const titleScript = [...text.matchAll(/<script[^>]*>(.*?)<\/script>/gs)]
        .map(x=>x[1]).find(x=>x.startsWith('var bundle='));
    const context = {cydia: {getLocalizedNameForDisplayIdentifier: id => {
        assert.equal(id,bundle); return names[id]; }}, document: {}};
    vm.runInNewContext(titleScript,context,{timeout:1000});
    assert.equal(context.document.title,names[bundle]);
    assert(frozen.pages[name].every(row => row.url === 'http://cydia.saurik.com/package/'+row.package));
}
console.log('PASS both child samples: localized title and all213 package destinations retained');

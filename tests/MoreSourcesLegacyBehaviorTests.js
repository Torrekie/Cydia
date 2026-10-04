#!/usr/bin/env node
// Actual original JS semantics, not native UI/source writes/OS-focus evidence.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.resolve(process.argv[2]);
const html=fs.readFileSync(path.join(root,'sources.html'),'utf8');
const frozen=JSON.parse(fs.readFileSync(path.join(root,'frozen-inputs.json')));
const script=[...html.matchAll(/<script[^>]*>(.*?)<\/script>/gs)].map(x=>x[1])
    .find(x=>x.startsWith('document.addEventListener("CydiaReloadData"'));
assert(script);
function run(sources,accepted=false,bridge=true){
    const removed=[],effects=[],callbacks=[],events={};
    const c={document:{addEventListener:(name,fn)=>events[name]=fn},
        window:{setTimeout:fn=>callbacks.push(fn),location:{reload:()=>effects.push(['reload'])}},
        confirm:message=>{effects.push(['confirm',message]);return accepted;},
        $:arg=>typeof arg==='function'?arg():{remove:()=>removed.push(arg)}};
    if(bridge)c.cydia={getAllSources:()=>sources,addSource:(...args)=>effects.push(['addSource',...args]),
        refreshSources:()=>effects.push(['refreshSources']),unload:()=>effects.push(['unload'])};
    vm.runInNewContext(script,c,{timeout:1000}); return {c,removed,effects,callbacks,events};
}
const rows=frozen.rows;
assert.deepEqual(rows.map(x=>x.identifier),['bigboss','modmyi','zodttd']);
assert.deepEqual(run([]).removed,[]);assert.deepEqual(run([],false,false).removed,[]);
console.log('PASS absent bridge/empty sources preserve three rows');
assert.deepEqual(run(rows).removed,['#bigboss','#modmyi','#zodttd','.defaultSources']);
console.log('PASS configured defaults hide rows and section');
assert.deepEqual(run([{rooturi:'http://apt.modmyi.com/',distribution:'stable'}]).removed,['#modmyi']);
assert.deepEqual(run([{rooturi:rows[0].rooturi,distribution:'other'}]).removed,[]);
console.log('PASS old ModMyi alias and exact distribution matching');
for(const row of rows){
    const cancel=run([]);cancel.c.add(row.name,row.rooturi,row.distribution,row.components);
    assert.deepEqual(cancel.effects,[['confirm','Add Source '+row.name+'?']]);assert.equal(cancel.callbacks.length,0);
    const accept=run([],true);accept.c.add(row.name,row.rooturi,row.distribution,row.components);
    assert.deepEqual(JSON.parse(JSON.stringify(accept.effects)),[
        ['confirm','Add Source '+row.name+'?'],['addSource',row.rooturi,row.distribution,row.components],['refreshSources']]);
    assert.equal(accept.callbacks.length,1);accept.callbacks[0]();assert.deepEqual(accept.effects.at(-1),['unload']);
}
console.log('PASS three exact tuples: Cancel no mutation; Confirm add/refresh/deferred unload');
const reload=run([]);reload.events.CydiaReloadData();assert.deepEqual(reload.effects,[['reload']]);
console.log('PASS original reload event');
assert.deepEqual(frozen.owned_children,[]);assert.equal(frozen.blocks.length,2);
console.log('PASS one owned page/two text blocks; no package or child route');

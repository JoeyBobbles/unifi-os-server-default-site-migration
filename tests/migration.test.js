// Synthetic Mongo facade: exercises the actual Mongo program without a controller.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const program = fs.readFileSync('migration.js', 'utf8');
const OLD = '111111111111111111111111';
const TARGET = '222222222222222222222222';
const SYSTEM = '333333333333333333333333';
function ObjectId(id) { return {toHexString: () => id}; }
function same(a, b) {
    return (a && a.toHexString ? a.toHexString() : a) === (b && b.toHexString ? b.toHexString() : b);
}
function matches(doc, query) {
    return Object.keys(query).every(key => {
        if (key === '$or') return query[key].some(q => matches(doc, q));
        const value = query[key];
        if (value && typeof value === 'object' && '$exists' in value) return (doc[key] !== undefined) === value.$exists;
        return same(doc[key], value);
    });
}
function fixture() {
    return {
        site: [
            {_id: ObjectId(OLD), name: 'default', attr_hidden_id: 'default', attr_no_delete: true},
            {_id: ObjectId(TARGET), name: 'imported'},
            {_id: ObjectId(SYSTEM), name: 'super', attr_hidden_id: 'super'}
        ],
        device: [], setting: [{_id: ObjectId('444444444444444444444444'), site_id: TARGET}],
        networkconf: [], wlanconf: []
    };
}
function run(data, target = TARGET, action = 'check') {
    const output = [], writes = [];
    const db = {getCollectionNames: () => Object.keys(data)};
    db.getCollection = name => ({
        find: (q = {}) => {
            const rows = (data[name] || []).filter(d => matches(d, q));
            return {toArray: () => rows, forEach: fn => rows.forEach(fn)};
        },
        count: q => (data[name] || []).filter(d => matches(d, q)).length,
        updateOne: () => { writes.push(name); throw Error('Unexpected write'); },
        deleteMany: () => { writes.push(name); throw Error('Unexpected write'); },
        deleteOne: () => { writes.push(name); throw Error('Unexpected write'); }
    });
    Object.keys(data).forEach(name => { db[name] = db.getCollection(name); });
    vm.runInNewContext(program, {db, ObjectId, target, action, print: line => output.push(line)});
    return {output: output.join('\n'), writes};
}
let passed = 0;
function test(name, fn) { fn(); passed++; console.log('ok ' + name); }
function rejected(change, target = TARGET) {
    const data = fixture(); change(data);
    const result = run(data, target);
    assert.match(result.output, /UOS FAIL/);
    assert.doesNotMatch(result.output, /UOS READY/);
    assert.equal(result.writes.length, 0);
}
test('valid preflight is read only', () => {
    const data = fixture(), before = JSON.stringify(data), result = run(data);
    assert.match(result.output, /UOS READY/);
    assert.equal(JSON.stringify(data), before);
    assert.equal(result.writes.length, 0);
});
test('unique candidate inferred', () => assert.match(run(fixture(), '').output, /UOS READY/));
test('missing Default', () => rejected(d => { d.site.shift(); }));
test('missing imported site', () => rejected(d => { d.site.splice(1, 1); }));
test('additional site', () => rejected(d => { d.site.push({_id: ObjectId('555555555555555555555555'), name: 'extra'}); }));
test('incorrect site selection', () => rejected(() => {}, '666666666666666666666666'));
test('system site selection', () => rejected(() => {}, SYSTEM));
test('Default selection', () => rejected(() => {}, OLD));
test('Default device string reference', () => rejected(d => { d.device.push({site_id: OLD}); }));
test('Default device ObjectId reference', () => rejected(d => { d.device.push({site_id: ObjectId(OLD)}); }));
test('no imported configuration', () => rejected(d => { d.setting = []; }));
test('unsupported identity type', () => rejected(d => { d.site[1]._id = TARGET; }));
test('unsupported site reference', () => rejected(d => { d.setting[0].site_id = 123; }));
test('orphan reference', () => rejected(d => { d.setting[0].site_id = '777777777777777777777777'; }));
test('unknown Default references', () => rejected(d => { d.unreviewed = [{site_id: OLD}]; }));
test('partial flag move', () => rejected(d => { delete d.site[0].attr_hidden_id; d.site[1].attr_hidden_id = 'default'; }));
test('duplicate name', () => rejected(d => { d.site[1].name = 'default'; }));
test('duplicate Default', () => rejected(d => { d.site[1].attr_hidden_id = 'default'; }));
test('missing device collection', () => rejected(d => { delete d.device; }));
test('completed topology recognised conservatively', () => {
    const d = fixture(); d.site.shift(); Object.assign(d.site[0], {name: 'default', attr_hidden_id: 'default', attr_no_delete: true});
    assert.match(run(d).output, /UOS ALREADY_DEFAULT/);
});
console.log(passed + ' tests passed');

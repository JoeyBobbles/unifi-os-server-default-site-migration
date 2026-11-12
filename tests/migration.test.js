// Synthetic Mongo facade: exercises the actual Mongo program without a controller.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const program = fs.readFileSync('migration.js', 'utf8');
const OLD = '111111111111111111111111';
const TARGET = '222222222222222222222222';
const SYSTEM = '333333333333333333333333';
function ObjectId(id) {
    if (!(this instanceof ObjectId)) return new ObjectId(id);
    this.toHexString = () => id;
}
function same(a, b) {
    const value = v => v instanceof ObjectId ? (v.toHexString ? v.toHexString() : v.str) : v;
    return value(a) === value(b);
}
function matches(doc, query) {
    return Object.keys(query).every(key => {
        if (key === '$or') return query[key].some(q => matches(doc, q));
        const value = query[key];
        if (value && typeof value === 'object' && '$exists' in value) return (doc[key] !== undefined) === value.$exists;
        return typeof doc[key] === typeof value && same(doc[key], value);
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
function run(data, target = TARGET, action = 'check', failAt = 0, response = 'throw') {
    const output = [], writes = [];
    const db = {getCollectionNames: () => Object.keys(data)};
    db.getCollection = name => ({
        find: (q = {}) => {
            const rows = (data[name] || []).filter(d => matches(d, q));
            return {toArray: () => rows, forEach: fn => rows.forEach(fn)};
        },
        count: q => (data[name] || []).filter(d => matches(d, q)).length,
        updateOne: (q, update, options) => {
            assert.equal(options.writeConcern.j, true);
            writes.push(name);
            if (writes.length === failAt && response === 'throw') throw Error('private-driver-error');
            const doc = (data[name] || []).find(d => matches(d, q));
            if (doc) {
                Object.assign(doc, update.$set || {});
                Object.keys(update.$unset || {}).forEach(key => { delete doc[key]; });
            }
            if (writes.length === failAt) return {acknowledged: false, matchedCount: 1, modifiedCount: 1};
            return {acknowledged: true, matchedCount: doc ? 1 : 0, modifiedCount: doc ? 1 : 0};
        },
        deleteOne: (q, options) => {
            assert.equal(options.writeConcern.j, true);
            writes.push(name);
            if (writes.length === failAt && response === 'throw') throw Error('private-driver-error');
            const index = (data[name] || []).findIndex(d => matches(d, q));
            if (index >= 0) data[name].splice(index, 1);
            if (writes.length === failAt) return {acknowledged: false, deletedCount: 1};
            return {acknowledged: true, deletedCount: index >= 0 ? 1 : 0};
        }

    });
    Object.keys(data).forEach(name => { db[name] = db.getCollection(name); });
    vm.runInNewContext(program, {db, ObjectId, target, action, oldIdentity: OLD, print: line => output.push(line)});
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
test('legacy ObjectId str representation', () => {
    const d = fixture();
    d.site.forEach(s => { s._id.str = s._id.toHexString(); delete s._id.toHexString; });
    assert.match(run(d).output, /UOS READY/);
});
test('plain object masquerading as ObjectId rejected', () => rejected(d => { d.site[1]._id = {str: TARGET}; }));
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
test('activity history preflight is read only and reports retention', () => {
    const d = fixture();
    d.admin_activity_log = [{_id: ObjectId('aaaaaaaaaaaaaaaaaaaaaaaa'), site_id: OLD, event: 'synthetic'}];
    const before = JSON.stringify(d), result = run(d);
    assert.match(result.output, /UOS RETAIN history=admin_activity_log old_site_references=1 unchanged/);
    assert.match(result.output, /UOS READY/);
    assert.equal(result.writes.length, 0);
    assert.equal(JSON.stringify(d), before);
});
test('activity history survives promotion and completed verification', () => {
    const d = fixture();
    d.admin_activity_log = [{site_id: OLD}, {site_id: ObjectId(OLD)}, {site_id: TARGET}];
    const before = JSON.stringify(d.admin_activity_log);
    assert.match(run(d, TARGET, 'flags').output, /UOS READY/);
    const result = run(d, TARGET, 'cleanup');
    assert.match(result.output, /UOS READY/);
    assert.equal(result.writes.includes('admin_activity_log'), false);
    assert.match(run(d, TARGET, 'verify').output, /UOS READY/);
    assert.equal(JSON.stringify(d.admin_activity_log), before);
});
test('unrelated orphan activity reference still rejected', () => rejected(d => {
    d.admin_activity_log = [{site_id: '777777777777777777777777'}];
}));
test('unsupported activity reference still rejected', () => rejected(d => {
    d.admin_activity_log = [{site_id: [OLD]}];
}));
test('activity history cannot conceal Default devices', () => rejected(d => {
    d.admin_activity_log = [{site_id: OLD}]; d.device.push({site_id: OLD});
}));
test('all unreviewed Default reference collections reported together', () => {
    const d = fixture();
    d.extra_first = [{site_id: OLD}]; d.extra_second = [{site_id: OLD}];
    const result = run(d);
    assert.match(result.output, /UOS BLOCK collection=extra_first old_site_references=1/);
    assert.match(result.output, /UOS BLOCK collection=extra_second old_site_references=1/);
    assert.match(result.output, /UOS FAIL/);
    assert.equal(result.writes.length, 0);
});
test('retained history does not exempt AP or certificate configuration', () => rejected(d => {
    d.admin_activity_log = [{site_id: OLD}];
    d.apgroup = [{site_id: OLD}]; d.ssl_inspection_certificate = [{site_id: OLD}];
}));
test('partial flag move', () => rejected(d => { delete d.site[0].attr_hidden_id; d.site[1].attr_hidden_id = 'default'; }));
test('duplicate name', () => rejected(d => { d.site[1].name = 'default'; }));
test('duplicate Default', () => rejected(d => { d.site[1].attr_hidden_id = 'default'; }));
test('invalid cleanup record identity rejected before writes', () => rejected(d => { d.networkconf.push({_id: 'wrong-type', site_id: OLD}); }));
test('missing device collection', () => rejected(d => { delete d.device; }));
test('completed topology recognised conservatively', () => {
    const d = fixture(); d.site.shift(); Object.assign(d.site[0], {name: 'default', attr_hidden_id: 'default', attr_no_delete: true});
    assert.match(run(d).output, /UOS ALREADY_DEFAULT/);
});
test('successful promotion preserves imported and unrelated records', () => {
    const d = fixture();
    d.networkconf.push({_id: ObjectId('888888888888888888888888'), site_id: OLD});
    d.setting.push({_id: ObjectId('999999999999999999999999'), key: 'global'});
    const keep = JSON.stringify(d.setting);
    assert.match(run(d, TARGET, 'flags').output, /UOS READY/);
    assert.match(run(d, TARGET, 'cleanup').output, /UOS READY/);
    assert.match(run(d, TARGET, 'verify').output, /UOS READY/);
    assert.equal(JSON.stringify(d.setting), keep);
    assert.equal(d.site.find(s => same(s._id, TARGET)).name, 'default');
    assert.equal(d.site.some(s => same(s._id, OLD)), false);
    assert.equal(run(d, TARGET, 'cleanup').writes.length, 0);
});
for (const response of ['throw', 'unacknowledged']) {
    for (const index of [1, 2]) {
        test('flag write failure ' + index + ' ' + response, () => {
            const d = fixture(), result = run(d, TARGET, 'flags', index, response);
            assert.match(result.output, /UOS FAIL/);
            assert.doesNotMatch(result.output, /private-driver-error/);
            assert.equal(result.writes.length, index);
            if (index === 2 || response !== 'throw') assert.doesNotMatch(run(d).output, /UOS READY/);
        });
    }
    for (const index of [1, 2, 3]) {
        test('cleanup write failure ' + index + ' ' + response, () => {
            const d = fixture();
            d.networkconf.push({_id: ObjectId('888888888888888888888888'), site_id: OLD});
            assert.match(run(d, TARGET, 'flags').output, /UOS READY/);
            const result = run(d, TARGET, 'cleanup', index, response);
            assert.match(result.output, /UOS FAIL/);
            assert.equal(result.writes.length, index);
            assert.doesNotMatch(run(d).output, /UOS READY/);
        });
    }
}
test('new Default device association after restart blocks cleanup', () => {
    const d = fixture(); run(d, TARGET, 'flags'); d.device.push({site_id: OLD});
    assert.equal(run(d, TARGET, 'cleanup').writes.length, 0);
});
test('unexpected target flag change blocks cleanup', () => {
    const d = fixture(); run(d, TARGET, 'flags'); d.site[1].attr_no_delete = false;
    assert.equal(run(d, TARGET, 'cleanup').writes.length, 0);
});
test('final verification rejects unexpected sites', () => {
    assert.match(run(fixture(), TARGET, 'verify').output, /UOS FAIL/);
});
console.log(passed + ' tests passed');

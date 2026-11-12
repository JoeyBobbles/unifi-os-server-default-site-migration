/* Mongo shell program; intentionally ES5-compatible for mongo and mongosh.
 * Inputs: target (validated ObjectId string or empty), action (check).
 * Never print documents, descriptions, credentials or server error messages.
 */
(function () {
    function reject(reason) { throw new Error(reason); }
    function hex(value) {
        if (!value || typeof value.toHexString !== 'function') reject('Non-ObjectId identity');
        var result = value.toHexString();
        if (!/^[0-9a-f]{24}$/.test(result)) reject('Invalid identity');
        return result;
    }
    function ref(id) { return {$or: [{site_id: id}, {site_id: ObjectId(id)}]}; }
    var cleanup = ['setting', 'networkconf', 'wlanconf', 'wlangroup',
        'usergroup', 'radiusprofile', 'dpigroup', 'privilege'];
    function inspect() {
        var names = db.getCollectionNames();
        ['site', 'device', 'setting', 'networkconf', 'wlanconf'].forEach(function (name) {
            if (names.indexOf(name) < 0) reject('Missing required collection: ' + name);
        });
        var sites = db.site.find().toArray(), defaults = [], users = [], system = [], seen = {};
        sites.forEach(function (s) {
            var id = hex(s._id);
            if (typeof s.name !== 'string' || !/^[a-zA-Z0-9_-]+$/.test(s.name)) reject('Unsupported site name');
            if (seen[s.name]) reject('Duplicate site name');
            seen[s.name] = true;
            if (s.name === 'super' || s.attr_hidden_id === 'super') {
                if (s.name !== 'super' || s.attr_hidden_id !== 'super') reject('Inconsistent system site');
                system.push(s);
            } else users.push(s);
            if (s.attr_hidden_id === 'default') defaults.push(s);
            print('UOS SITE ' + id + ' ' + s.name + ' ' + (s.attr_hidden_id === 'default' ? 'Default' : 'candidate/system'));
        });
        if (system.length !== 1) reject('Expected exactly one system site');
        if (defaults.length !== 1 || defaults[0].name === 'super') reject('Expected exactly one current Default');
        var old = defaults[0], selected;
        if (old.name !== 'default' || old.attr_no_delete !== true) reject('Partial migration or unsupported Default flags');
        if (users.length === 1) {
            if (target && hex(old._id) === target) {
                print('UOS ALREADY_DEFAULT (completed migration cannot be proven without journal)');
            }
            reject('No imported candidate; already Default or import missing');
        }
        if (users.length !== 2) reject('Unexpected additional sites');
        users.forEach(function (s) { if (hex(s._id) !== hex(old._id)) selected = s; });
        if (target && hex(selected._id) !== target) reject('Selected imported site not found or protected');
        if (selected.attr_hidden_id !== undefined || selected.attr_no_delete !== undefined) reject('Partial migration or unsupported imported flags');
        var oldId = hex(old._id), newId = hex(selected._id), config = 0;
        names.forEach(function (name) {
            // Any unknown collection with references to the old Default is unsafe
            // to leave orphaned. No broad cleanup or inferred deletion is allowed.
            var collection = db.getCollection(name);
            collection.find({site_id: {$exists: true}}).forEach(function (record) {
                var value = record.site_id, id;
                if (typeof value === 'string' && /^[0-9a-f]{24}$/.test(value)) id = value;
                else id = hex(value);
                if (!sites.some(function (s) { return hex(s._id) === id; })) reject('Orphan site reference in ' + name);
            });
            var count = collection.count(ref(oldId));
            if (name === 'device' && count !== 0) reject('Existing Default has device associations');
            if (count && cleanup.indexOf(name) < 0) reject('Unreviewed Default references in ' + name);
            if (['setting', 'networkconf', 'wlanconf'].indexOf(name) >= 0) config += collection.count(ref(newId));
        });
        if (config < 1) reject('Imported site has no configuration records');
        print('UOS PLAN target=' + newId + ' old=' + oldId + ' configuration_records=' + config);
        print('UOS PLAN move flags; restart; delete scoped Default configuration and site; rename imported site; restart');
        return {old: old, selected: selected, oldId: oldId, newId: newId, names: names};
    }
    try {
        if (action !== 'check') reject('Unsupported action');
        inspect();
        print('UOS READY');
    } catch (error) {
        // All messages originate locally; driver exceptions are deliberately hidden.
        var safe = ['Non-ObjectId identity', 'Invalid identity', 'Unsupported site name',
            'Duplicate site name', 'Inconsistent system site', 'Expected exactly one system site',
            'Expected exactly one current Default', 'Partial migration or unsupported Default flags',
            'No imported candidate; already Default or import missing', 'Unexpected additional sites',
            'Selected imported site not found or protected', 'Partial migration or unsupported imported flags',
            'Existing Default has device associations', 'Imported site has no configuration records', 'Unsupported action'];
        var message = String(error.message);
        if (safe.indexOf(message) < 0 && !/^(Missing required collection|Orphan site reference in|Unreviewed Default references in):? [a-zA-Z0-9_.-]+$/.test(message)) message = 'Database operation or schema validation failed';
        print('UOS FAIL ' + message);
    }
}());

/* Mongo shell program; intentionally ES5-compatible for mongo and mongosh.
 * Inputs: target (validated ObjectId string or empty), action (check/flags/cleanup/verify), oldIdentity for later phases.
 * Never print documents, descriptions, credentials or server error messages.
 */
(function () {
    function reject(reason) { throw new Error(reason); }
    function hex(value) {
        if (!value || !(value instanceof ObjectId)) reject('Non-ObjectId identity');
        // Legacy mongo exposes .str; mongosh uses the BSON conversion method.
        // https://www.mongodb.com/docs/mongodb-shell/reference/compatibility/
        var result = typeof value.toHexString === 'function' ? value.toHexString() : value.str;
        if (!/^[0-9a-f]{24}$/.test(result)) reject('Invalid identity');
        return result;
    }
    function ref(id) { return {$or: [{site_id: id}, {site_id: ObjectId(id)}]}; }
    var cleanup = ['setting', 'networkconf', 'wlanconf', 'wlangroup',
        'usergroup', 'radiusprofile', 'dpigroup', 'privilege'];
    function inspect(stage) {
        var names = db.getCollectionNames();
        ['site', 'device', 'setting', 'networkconf', 'wlanconf'].forEach(function (name) {
            if (names.indexOf(name) < 0) reject('Missing required collection: ' + name);
        });
        var sites = db.site.find().toArray(), defaults = [], users = [], system = [], seen = Object.create(null);
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
        if (stage === 'initial') {
            if (old.name !== 'default' || old.attr_no_delete !== true) reject('Partial migration or unsupported Default flags');
            if (users.length === 1) {
                if (target && hex(old._id) === target) print('UOS ALREADY_DEFAULT (completed migration cannot be proven without journal)');
                reject('No imported candidate; already Default or import missing');
            }
            if (users.length !== 2) reject('Unexpected additional sites');
            users.forEach(function (s) { if (hex(s._id) !== hex(old._id)) selected = s; });
            if (target && hex(selected._id) !== target) reject('Selected imported site not found or protected');
            if (selected.attr_hidden_id !== undefined || selected.attr_no_delete !== undefined) reject('Partial migration or unsupported imported flags');
        } else {
            if (!/^[0-9a-f]{24}$/.test(oldIdentity) || oldIdentity === target) reject('Invalid identity');
            users.forEach(function (s) {
                if (hex(s._id) === target) selected = s;
                if (hex(s._id) === oldIdentity) old = s;
            });
            if (!selected || selected.attr_hidden_id !== 'default' || selected.attr_no_delete !== true) reject('Unexpected phase state');
            if (stage === 'flags') {
                if (users.length !== 2 || hex(old._id) !== oldIdentity || old.name !== 'default' ||
                    old.attr_hidden_id !== undefined || old.attr_no_delete !== undefined || selected.name === 'default') reject('Unexpected phase state');
            } else {
                if (users.length !== 1 || hex(defaults[0]._id) !== target ||
                    (stage === 'final' ? selected.name !== 'default' : selected.name === 'default')) reject('Unexpected phase state');
                old = {_id: ObjectId(oldIdentity)};
            }
        }
        var oldId = hex(old._id), newId = hex(selected._id), config = 0;
        names.forEach(function (name) {
            // Any unknown collection with references to the old Default is unsafe
            // to leave orphaned. No broad cleanup or inferred deletion is allowed.
            var collection = db.getCollection(name);
            if (typeof collection.deleteOne !== 'function' || typeof db.site.updateOne !== 'function') reject('Unsupported write API');
            collection.find({site_id: {$exists: true}}).forEach(function (record) {
                var value = record.site_id, id;
                if (typeof value === 'string' && /^[0-9a-f]{24}$/.test(value)) id = value;
                else id = hex(value);
                if (id === oldId && cleanup.indexOf(name) >= 0) hex(record._id);
                if (!sites.some(function (s) { return hex(s._id) === id; })) reject('Orphan site reference in ' + name);
            });
            var count = collection.count(ref(oldId));
            if (name === 'device' && count !== 0) reject('Existing Default has device associations');
            if (count && cleanup.indexOf(name) < 0) reject('Unreviewed Default references in ' + name);
            if (['setting', 'networkconf', 'wlanconf'].indexOf(name) >= 0) config += collection.count(ref(newId));
        });
        if (config < 1) reject('Imported site has no configuration records');
        if (stage === 'initial') print('UOS PLAN target=' + newId + ' old=' + oldId + ' configuration_records=' + config);
        if (stage === 'initial') print('UOS PLAN move flags; restart; delete scoped Default configuration and site; rename imported site; restart');
        return {old: old, selected: selected, oldId: oldId, newId: newId, names: names};
    }
    var options = {writeConcern: {w: 1, j: true, wtimeout: 10000}};
    function updated(result) {
        if (!result || result.acknowledged !== true || result.matchedCount !== 1 || result.modifiedCount !== 1) reject('Write acknowledgement mismatch');
        print('UOS WRITE update matched=1 modified=1');
    }
    function deleted(result) {
        if (!result || result.acknowledged !== true || result.deletedCount !== 1) reject('Write acknowledgement mismatch');
        print('UOS WRITE delete count=1');
    }
    function protectedSite(site, hidden, noDelete) {
        return {_id: site._id, name: site.name,
            attr_hidden_id: hidden === undefined ? {$exists: false} : hidden,
            attr_no_delete: noDelete === undefined ? {$exists: false} : noDelete};
    }
    try {
        if (action === 'check') inspect('initial');
        else if (action === 'verify') inspect('final');
        else if (action === 'flags') {
            var state = inspect('initial');
            if (!target || state.oldId !== oldIdentity) reject('Unexpected phase state');
            updated(db.site.updateOne(protectedSite(state.old, 'default', true),
                {$unset: {attr_hidden_id: '', attr_no_delete: ''}}, options));
            updated(db.site.updateOne(protectedSite(state.selected),
                {$set: {attr_hidden_id: 'default', attr_no_delete: true}}, options));
            inspect('flags');
        } else if (action === 'cleanup') {
            var current = inspect('flags');
            cleanup.forEach(function (name) {
                if (current.names.indexOf(name) < 0) return;
                var collection = db.getCollection(name);
                // Snapshot identities; never delete records created after this read.
                var records = collection.find(ref(oldIdentity)).toArray();
                records.forEach(function (record) {
                    inspect('flags');
                    hex(record._id);
                    deleted(collection.deleteOne({_id: record._id, site_id: record.site_id}, options));
                });
                if (collection.count(ref(oldIdentity)) !== 0) reject('Unexpected phase state');
                print('UOS WRITE collection=' + name + ' deleted=' + records.length);
            });
            current = inspect('flags');
            current.names.forEach(function (name) {
                if (db.getCollection(name).count(ref(oldIdentity)) !== 0) reject('Unexpected phase state');
            });
            deleted(db.site.deleteOne(protectedSite(current.old), options));
            current = inspect('deleted');
            updated(db.site.updateOne(protectedSite(current.selected, 'default', true), {$set: {name: 'default'}}, options));
            inspect('final');
        } else reject('Unsupported action');
        print('UOS READY');
    } catch (error) {
        // All messages originate locally; driver exceptions are deliberately hidden.
        var safe = ['Non-ObjectId identity', 'Invalid identity', 'Unsupported site name',
            'Duplicate site name', 'Inconsistent system site', 'Expected exactly one system site',
            'Expected exactly one current Default', 'Partial migration or unsupported Default flags',
            'No imported candidate; already Default or import missing', 'Unexpected additional sites',
            'Selected imported site not found or protected', 'Partial migration or unsupported imported flags',
            'Unsupported write API', 'Unexpected phase state', 'Write acknowledgement mismatch', 'Existing Default has device associations', 'Imported site has no configuration records', 'Unsupported action'];
        var message = String(error.message);
        if (safe.indexOf(message) < 0 && !/^(Missing required collection|Orphan site reference in|Unreviewed Default references in):? [a-zA-Z0-9_.-]+$/.test(message)) message = 'Database operation or schema validation failed';
        print('UOS FAIL ' + message);
    }
}());

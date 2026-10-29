import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const collection = JSON.parse(readFileSync(new URL('./TCGTracking-Research.postman_collection.json', import.meta.url)));
const environment = JSON.parse(readFileSync(new URL('./TCGTracking-Local.postman_environment.json', import.meta.url)));
const pre = collection.event.find(e => e.listen === 'prerequest').script.exec.join('\n');
const secrets = {tcgt_shipper_id: 'fixture-shipper', tcgt_beta_key: 'fixture-secret-never-export'};
// Shape and set counts from the user's Research index, without unrelated sets.
const index = {schema_version: '2.0-testing', status: 'in_testing', categories: {
    '3': {category_id: 3, game_name: 'Pokemon', sets: {
        '22872': {category_id: 3, group_id: 22872, set_name: 'SV: Scarlet & Violet Promo Cards',
            product_count: 1, grade_row_count: 25,
            url: 'https://beta.tcgtracking.com/v1/3/sets/22872/research'},
    }},
}};

function harness(credentials = secrets) {
    const values = new Map(collection.variable.map(v => [v.key, v.value]));
    function run(number, body, {code = 200, url, malformed = false} = {}) {
        const item = collection.item[number - 1];
        const local = new Map();
        const headers = new Map(item.request.header.map(h => [h.key.toLowerCase(), h.value]));
        const output = {tests: [], logs: [], skipped: false, next: undefined, headers};
        const variables = {
            get(key) { return local.has(key) ? local.get(key) : (credentials[key] ?? values.get(key)); },
            set(key, value) { local.set(key, value); },
            replaceIn(text) { return text.replace(/\{\{([^}]+)\}\}/g, (_, key) => String(this.get(key) ?? '{{' + key + '}}')); },
        };
        const pm = {
            info: {requestName: item.name}, variables,
            environment: {get: key => credentials[key]},
            collectionVariables: {get: key => values.get(key), set: (key, value) => values.set(key, value), unset: key => values.delete(key)},
            request: {url: {toString: () => url ?? item.request.url}, headers: {
                remove: key => headers.delete(key.toLowerCase()),
                upsert: ({key, value}) => headers.set(key.toLowerCase(), value),
            }},
            execution: {setNextRequest: value => { output.next = value; }, skipRequest: () => { output.skipped = true; }},
            response: {code, json() { if (malformed) { throw new Error('malformed JSON'); } return body; }},
            test(name, fn) { try { fn(); output.tests.push({name, passed: true}); } catch (error) { output.tests.push({name, passed: false, error: error.message}); } },
            visualizer: {set: (template, data) => { output.visualizer = {template, data}; }},
        };
        const context = vm.createContext({pm, console: {log: (...args) => output.logs.push(args)}});
        try { vm.runInContext(pre, context); } catch (error) { output.preError = error.message; }
        output.url = variables.replaceIn(url ?? item.request.url);
        if (!output.preError && !output.skipped) {
            vm.runInContext(item.event.find(e => e.listen === 'test').script.exec.join('\n'), context);
        }
        output.summary = values.has('tcgt_research_summary') ? JSON.parse(values.get('tcgt_research_summary')) : null;
        return output;
    }
    return {values, run};
}

function shard({key = '512035', productID = 512035, groupID = 22872, variants, grades} = {}) {
    return {meta: {category_id: 3, group_id: groupID}, products: {[key]: {
        product_id: productID, name: 'Charmander', ext_number: '044', variants: variants ?? {
            'EN:Holofoil': {language: 'EN', finish: 'Holofoil', grades: grades ?? [
                {grader: 'PSA', grade: '9', pop: 0, sales: 0, guide_value: 0, market_value: null},
            ]},
        },
    }}};
}

function ready() {
    const h = harness();
    const first = h.run(1, index);
    assert.equal(first.summary.status, 'set_resolved');
    assert(first.tests.every(t => t.passed));
    return h;
}

test('importable v2.1 collection contains three read-only fixed-host requests and empty secret environment', () => {
    assert.equal(collection.info.schema, 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json');
    assert.equal(collection.item.length, 3);
    assert(collection.item.every(item => item.request.method === 'GET' && item.request.auth.type === 'noauth'));
    assert(collection.item.every(item => item.protocolProfileBehavior.followRedirects === false));
    assert(environment.values.every(v => v.value === '' && v.type === 'secret' && v.enabled));
    assert(!collection.variable.some(v => ['tcgt_shipper_id', 'tcgt_beta_key'].includes(v.key)));
});

test('supplied Research index automatically resolves set 22872 and its coverage counts', () => {
    const h = ready();
    assert.equal(h.values.get('tcgt_resolved_group_id'), '22872');
    assert.equal(h.values.get('tcgt_index_product_count'), '1');
    assert.equal(h.values.get('tcgt_index_grade_row_count'), '25');
    const result = h.run(3, shard());
    assert.equal(result.url, 'https://beta.tcgtracking.com/v1/3/sets/22872/research');
    assert.equal(result.headers.get('x-api-key'), secrets.tcgt_beta_key);
    assert.equal(result.headers.get('x-shipper-id'), secrets.tcgt_shipper_id);
});

test('public set check sends no Beta credentials and does not assume a catalog wrapper', () => {
    const h = ready();
    const result = h.run(2, [{id: 22872, name: 'SV: Scarlet & Violet Promo Cards'}]);
    assert(!result.headers.has('x-api-key'));
    assert(!result.headers.has('x-shipper-id'));
    assert(!result.headers.has('authorization'));
    assert(result.tests.every(t => t.passed));
    assert.equal(result.summary.status, 'set_resolved');
});

test('exact PSA 9 row is available independently of null valuation or returned zeroes', () => {
    const result = ready().run(3, shard());
    assert(result.tests.every(t => t.passed));
    assert.equal(result.summary.status, 'available');
    assert.equal(result.summary.selected_grade.market_value, null);
    assert.equal(result.summary.selected_grade.guide_value, 0);
    assert.equal(result.summary.selected_grade.pop, 0);
    assert.equal(result.summary.selected_grade.sales, 0);
    assert(!JSON.stringify(result.summary).includes(secrets.tcgt_beta_key));
    assert(!JSON.stringify(result.logs).includes(secrets.tcgt_beta_key));
    assert(!JSON.stringify(result.visualizer).includes(secrets.tcgt_shipper_id));
});

test('successful set with another product fails coverage while preserving HTTP success and returned identities', () => {
    const result = ready().run(3, shard({key: '42', productID: 42}));
    assert.equal(result.summary.status, 'product_missing');
    assert.equal(result.summary.http_status, 200);
    assert.equal(result.summary.returned_product_count, 1);
    assert.equal(result.summary.returned_product_sample[0].product_id, 42);
    assert(result.tests.find(t => t.name === 'Card Research HTTP 200').passed);
    assert(!result.tests.find(t => t.name === 'Exact product 512035 is present').passed);
});

test('unexpected prefixed keys and wrong product identity are distinguished from genuine absence', () => {
    for (const key of ['p:512035', 'p512035']) {
        const result = ready().run(3, shard({key}));
        assert.equal(result.summary.status, 'unexpected_product_keys');
        assert.equal(result.summary.alternate_product_keys[0], key);
    }
    assert.equal(ready().run(3, shard({productID: 42})).summary.status, 'invalid_product');
});

test('a wrong set or malformed response is not reported as missing card coverage', () => {
    assert.equal(ready().run(3, shard({groupID: 1})).summary.status, 'identity_mismatch');
    assert.equal(ready().run(3, {meta: {}, products: []}).summary.status, 'invalid_response');
    assert.equal(ready().run(3, null, {malformed: true}).summary.status, 'invalid_response');
});

test('another printing, PSA 10 and RAW never substitute for the selected variant and PSA 9', () => {
    assert.equal(ready().run(3, shard({variants: {}})).summary.status, 'variant_missing');
    const result = ready().run(3, shard({grades: [{grader: 'PSA', grade: '10'}, {grader: 'RAW', grade: 'Raw'}]}));
    assert.equal(result.summary.status, 'grade_missing');
    assert.equal(result.summary.available_grades.length, 2);
    const duplicate = ready().run(3, shard({grades: [{grader: 'PSA', grade: '9'}, {grader: 'PSA', grade: '9'}]}));
    assert.equal(duplicate.summary.status, 'grade_ambiguous');
});

test('authentication and rate limit responses are reported separately from coverage', () => {
    for (const code of [401, 403, 404, 429, 503]) {
        const result = ready().run(3, {error: 'fixture-provider-error'}, {code});
        assert.equal(result.summary.status, 'http_error');
        assert.equal(result.summary.http_status, code);
    }
});

test('new runs clear old success and set IDs before failed or ambiguous discovery', () => {
    const h = ready();
    assert.equal(h.run(3, shard()).summary.status, 'available');
    const denied = h.run(1, {error: 'denied'}, {code: 403});
    assert.equal(denied.summary.status, 'connection_error');
    assert.equal(denied.next, null);
    assert(!h.values.has('tcgt_resolved_group_id'));
    const skipped = h.run(3, shard());
    assert(skipped.skipped);
    assert.equal(skipped.summary, null);
    const missing = harness().run(1, {categories: {'3': {sets: {}}}});
    assert.equal(missing.summary.status, 'set_not_indexed');
    const duplicate = structuredClone(index);
    duplicate.categories['3'].sets['99999'] = {...duplicate.categories['3'].sets['22872'], group_id: 99999};
    assert.equal(harness().run(1, duplicate).summary.status, 'ambiguous_set');
});

test('missing credentials, untrusted endpoints and path injection are blocked before sending', () => {
    assert(harness({}).run(1, index).skipped);
    const changedHost = harness().run(1, index, {url: 'https://other.example.com/v1/research/meta'});
    assert(changedHost.skipped);
    assert(!changedHost.headers.has('x-api-key'));
    const h = harness();
    h.values.set('tcgt_category_id', '3/../../other');
    assert(h.run(1, index).skipped);
});

test('a new failed card request replaces a prior successful summary', () => {
    const h = ready();
    assert.equal(h.run(3, shard()).summary.status, 'available');
    const result = h.run(3, {meta: {category_id: 3, group_id: 22872}, products: {}});
    assert.equal(result.summary.status, 'product_missing');
    assert(!Object.hasOwn(result.summary, 'selected_grade'));
});

test('individual sends cannot reuse a derived set after changing its category or name', () => {
    for (const [key, value] of [['tcgt_set_name', 'Another set'], ['tcgt_category_id', '1']]) {
        const h = ready();
        assert.equal(h.run(3, shard()).summary.status, 'available');
        h.values.set(key, value);
        const result = h.run(3, shard());
        assert(result.skipped);
        assert.match(result.preError, /target category or set changed/);
        assert.equal(result.summary, null);
        assert(!result.headers.has('x-api-key'));
    }
});

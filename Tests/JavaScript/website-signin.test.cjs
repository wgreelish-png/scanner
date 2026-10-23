const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const source = fs.readFileSync(path.join(__dirname, '../../CardShowScanner/Resources/WebsiteSignIn.js'), 'utf8');
const execute = new AsyncFunction('username', 'password', 'submit', 'navigate', 'location', 'document',
  'HTMLInputElement', 'HTMLFormElement', 'Event', 'getComputedStyle', 'URL', source);

class Element {
  constructor(tagName, attrs = {}) {
    this.tagName = tagName.toUpperCase(); this.attrs = attrs; this.id = attrs.id || '';
    this.name = attrs.name || ''; this.textContent = attrs.text || '';
    this.hidden = Boolean(attrs.hidden); this.disabled = Boolean(attrs.disabled);
    this.readOnly = Boolean(attrs.readOnly); this.isConnected = attrs.connected !== false;
    this.inert = Boolean(attrs.inert); this.css = attrs.css || {};
    this.events = []; this.form = null;
  }
  getAttribute(name) { return Object.hasOwn(this.attrs, name) ? this.attrs[name] : null; }
  hasAttribute(name) { return Object.hasOwn(this.attrs, name); }
  matches() { return this.disabled; }
  closest() { return this.inert ? {} : null; }
  getClientRects() { return this.hidden ? [] : [{ width: 200, height: 44 }]; }
  dispatchEvent(event) { this.events.push(event.type); return true; }
}
class Input extends Element {
  constructor(attrs = {}) {
    super('input', attrs); this.type = attrs.type || 'text'; this.autocomplete = attrs.autocomplete || '';
    this._value = attrs.value || ''; this.valueWrites = 0;
  }
  get value() { return this._value; }
  set value(value) { this._value = value; this.valueWrites++; }
}
class Button extends Element {
  constructor(attrs = {}) {
    super('button', attrs); this.type = attrs.type || 'submit'; this.value = attrs.value || '';
    this.formAction = attrs.formaction || ''; this.formMethod = attrs.formmethod || '';
  }
}
class Form extends Element {
  constructor(options = {}) {
    super('form', { id: options.id || 'login-form', name: options.name || '' });
    this.action = options.action || 'https://tcgtracking.com/login.php'; this.method = options.method || 'post';
    this.inputs = options.inputs || [new Input({ name: 'email', type: 'email', autocomplete: 'username' }),
      new Input({ type: 'password', autocomplete: 'current-password' }),
      new Input({ type: 'hidden', name: 'csrf', value: 'fixture-csrf' })];
    this.buttons = options.buttons || [new Button({ text: 'Sign in' })];
    this.challenges = options.challenges || []; this.valid = options.valid !== false;
    this.submissions = []; this.validityChecks = 0;
    for (const item of [...this.inputs, ...this.buttons, ...this.challenges]) item.form = this;
  }
  querySelectorAll(selector) {
    if (selector === 'input' || selector === 'input,textarea') return this.inputs;
    if (selector === 'button,input[type="submit"]') return this.buttons;
    if (selector === 'iframe,.g-recaptcha,.h-captcha,.cf-turnstile') return this.challenges;
    throw new Error('Unexpected fixture selector');
  }
  contains(element) { return [...this.inputs, ...this.buttons, ...this.challenges].includes(element); }
  checkValidity() { this.validityChecks++; return this.valid; }
  requestSubmit(button) { if (this.valid) this.submissions.push(button); }
}
class Anchor extends Element {
  constructor(attrs = {}) { super('a', attrs); this.href = attrs.href || ''; }
}
function fixture(options = {}) {
  const form = options.form || new Form();
  const forms = options.forms || [form]; const anchors = options.anchors || [];
  const navigations = [];
  const location = { href: options.href || 'https://tcgtracking.com/login.php', assign(url) { navigations.push(url); } };
  const document = { readyState: options.readyState || 'complete', querySelectorAll(selector) {
    if (selector === 'form') return forms;
    if (selector === 'a[href]') return anchors;
    throw new Error('Unexpected fixture selector');
  } };
  return { form, forms, navigations, async run(args = {}) {
    return execute(args.username ?? 'trainer@example.com', args.password ?? 'fixture-password', args.submit ?? false,
      args.navigate ?? false, location, document, Input, Form, Event,
      element => ({ display: 'block', visibility: 'visible', ...element.css }), URL);
  } };
}

test('a read-only probe identifies a normal login form without reading back credentials', async () => {
  const f = fixture();
  assert.deepEqual(await f.run(), { status: 'ready' });
  assert.deepEqual(f.form.inputs.map(input => input.valueWrites), [0, 0, 0]);
  assert.equal(f.form.submissions.length, 0); assert.deepEqual(f.navigations, []);
});
test('structured Unicode credentials use native setters and normal form submission without altering CSRF', async () => {
  const f = fixture();
  const username = 'Pokémon+"quoted"@example.com'; const password = '`$()\\"\n秘密🃏';
  assert.deepEqual(await f.run({ submit: true, username, password }), { status: 'submitted' });
  assert.equal(f.form.inputs[0].value, username); assert.equal(f.form.inputs[1].value, password);
  assert.deepEqual(f.form.inputs[0].events, ['input', 'change']);
  assert.deepEqual(f.form.inputs[1].events, ['input', 'change']);
  assert.equal(f.form.inputs[2].value, 'fixture-csrf'); assert.equal(f.form.inputs[2].valueWrites, 0);
  assert.deepEqual(f.form.submissions, [f.form.buttons[0]]); assert.equal(f.form.validityChecks, 1);
});
test('only the genuine first-party HTTPS page can receive credentials', async () => {
  for (const href of ['http://tcgtracking.com/login.php', 'https://tcgtracking.com.evil/login.php',
    'https://user:secret@tcgtracking.com/login.php', 'https://tcgtracking.com:444/login.php', 'https://example.com/']) {
    const f = fixture({ href });
    assert.deepEqual(await f.run({ submit: true }), { status: 'unsupported' });
    assert.equal(f.form.inputs[0].valueWrites, 0);
  }
  assert.deepEqual(await fixture({ href: 'https://www.tcgtracking.com/login.php',
    form: new Form({ action: 'https://www.tcgtracking.com/login.php' }) }).run(), { status: 'ready' });
});
test('unsafe actions, GET passwords and unsafe submit-button overrides are refused before filling', async () => {
  for (const form of [new Form({ action: 'http://tcgtracking.com/login.php' }),
    new Form({ action: 'https://evil.example/login' }), new Form({ method: 'get' }),
    new Form({ buttons: [new Button({ text: 'Sign in', formaction: 'https://evil.example/login' })] }),
    new Form({ buttons: [new Button({ text: 'Sign in', formmethod: 'get' })] })]) {
    const f = fixture({ form });
    assert.deepEqual(await f.run({ submit: true }), { status: 'unsupported' });
    assert.equal(form.inputs[0].valueWrites, 0); assert.equal(form.submissions.length, 0);
  }
});
test('registration, reset and ambiguous password forms cannot be mistaken for login', async () => {
  const forms = [new Form({ action: 'https://tcgtracking.com/register.php' }),
    new Form({ action: 'https://tcgtracking.com/reset-password' }),
    new Form({ buttons: [new Button({ text: 'Register' })] }),
    new Form({ buttons: [new Button({ text: 'Create account' })] }),
    new Form({ buttons: [new Button({ text: 'Set password' })] }),
    new Form({ inputs: [new Input({ name: 'email', type: 'email' }), new Input({ type: 'password', autocomplete: 'new-password' })] }),
    new Form({ inputs: [new Input({ name: 'email', type: 'email' }), new Input({ type: 'password' }), new Input({ type: 'password' })] })];
  for (const form of forms) {
    assert.deepEqual(await fixture({ form }).run({ submit: true }), { status: 'unsupported' });
    assert.equal(form.submissions.length, 0); assert.ok(form.inputs.every(input => input.valueWrites === 0));
  }
  const f = fixture({ forms: [new Form(), new Form()] });
  assert.deepEqual(await f.run({ submit: true }), { status: 'unsupported' });
});
test('hidden, disabled, detached and ambiguous username fields are never filled', async () => {
  for (const attrs of [{ hidden: true }, { disabled: true }, { readOnly: true }, { connected: false },
    { css: { visibility: 'hidden' } }, { inert: true }]) {
    const form = new Form(); Object.assign(form.inputs[0], new Input({ name: 'email', type: 'email', ...attrs }));
    form.inputs[0].form = form;
    assert.deepEqual(await fixture({ form }).run({ submit: true }), { status: 'unsupported' });
    assert.ok(form.inputs.every(input => input.valueWrites === 0));
  }
  const form = new Form({ inputs: [new Input({ type: 'email' }), new Input({ type: 'email' }), new Input({ type: 'password' })] });
  assert.deepEqual(await fixture({ form }).run({ submit: true }), { status: 'unsupported' });
});
test('verification remains on the website and never triggers automatic submission', async () => {
  const challenge = new Element('iframe', { src: 'https://challenges.cloudflare.com/widget' });
  const f = fixture({ form: new Form({ challenges: [challenge] }) });
  assert.deepEqual(await f.run(), { status: 'verification_required' });
  assert.equal(f.form.inputs[0].valueWrites, 0);
  assert.deepEqual(await f.run({ submit: true }), { status: 'verification_required' });
  assert.equal(f.form.inputs[0].value, 'trainer@example.com'); assert.equal(f.form.submissions.length, 0);
  f.form.inputs.push(new Input({ type: 'hidden', name: 'cf-turnstile-response', value: 'fixture-response' }));
  assert.deepEqual(await f.run({ submit: true }), { status: 'submitted' });
});
test('browser validation and clobbered form properties cannot bypass the normal submission path', async () => {
  const f = fixture({ form: new Form({ valid: false }) });
  assert.deepEqual(await f.run({ submit: true }), { status: 'unsupported' });
  assert.equal(f.form.submissions.length, 0);
  const valid = fixture(); valid.form.requestSubmit = 'clobbered'; valid.form.checkValidity = 'clobbered';
  assert.deepEqual(await valid.run({ submit: true }), { status: 'submitted' });
  assert.equal(valid.form.submissions.length, 1);
});
test('input handlers cannot switch the form to an unsafe destination before submission', async () => {
  const f = fixture();
  f.form.inputs[1].dispatchEvent = () => { f.form.action = 'https://evil.example/login'; };
  assert.deepEqual(await f.run({ submit: true }), { status: 'unsupported' });
  assert.equal(f.form.submissions.length, 0);
});
test('empty or oversized credentials and incomplete documents cannot submit', async () => {
  for (const args of [{ username: '' }, { username: ' ' }, { password: '' },
    { username: 'x'.repeat(513) }, { password: 'x'.repeat(8193) }]) {
    const f = fixture();
    assert.deepEqual(await f.run({ ...args, submit: true }), { status: 'unsupported' });
    assert.ok(f.form.inputs.every(input => input.valueWrites === 0));
  }
  assert.deepEqual(await fixture({ readyState: 'loading' }).run({ submit: true }), { status: 'unsupported' });
});
test('an explicit navigation probe follows one visible trusted Login link without sending credentials', async () => {
  const f = fixture({ forms: [], href: 'https://tcgtracking.com/',
    anchors: [new Anchor({ text: 'Log in', href: 'https://tcgtracking.com/account/login' })] });
  assert.deepEqual(await f.run(), { status: 'not_found' }); assert.deepEqual(f.navigations, []);
  assert.deepEqual(await f.run({ navigate: true }), { status: 'navigating' });
  assert.deepEqual(f.navigations, ['https://tcgtracking.com/account/login']);
});
test('navigation never guesses endpoints or follows ambiguous, unsafe or non-login links', async () => {
  for (const anchors of [[], [new Anchor({ text: 'Register', href: 'https://tcgtracking.com/register' })],
    [new Anchor({ text: 'Login', href: 'http://tcgtracking.com/login' })],
    [new Anchor({ text: 'Login', href: 'https://evil.example/login' })],
    [new Anchor({ text: 'Login', href: 'https://user:secret@tcgtracking.com/login' })],
    [new Anchor({ text: 'Login', href: 'https://tcgtracking.com/login', hidden: true })],
    [new Anchor({ text: 'Login', href: 'https://tcgtracking.com/login', download: '' })],
    [new Anchor({ text: 'Login', href: 'https://tcgtracking.com/login' }), new Anchor({ text: 'Sign in', href: 'https://tcgtracking.com/account' })]]) {
    const f = fixture({ forms: [], anchors });
    assert.deepEqual(await f.run({ navigate: true }), { status: 'not_found' });
    assert.deepEqual(f.navigations, []);
  }
});
test('bounded discovery refuses oversized pages without exposing their content', async () => {
  const f = fixture({ forms: new Array(33).fill(new Form()) });
  assert.deepEqual(await f.run(), { status: 'unsupported' });
  const links = fixture({ forms: [], anchors: new Array(257).fill(new Anchor({ text: 'Login', href: 'https://tcgtracking.com/login' })) });
  assert.deepEqual(await links.run({ navigate: true }), { status: 'unsupported' });
});

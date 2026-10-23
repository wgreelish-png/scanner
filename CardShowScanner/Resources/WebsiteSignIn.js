/* Function body for WKWebView.callAsyncJavaScript on the visible TCGTracking
 * website. username/password/submit/navigate are structured arguments, never
 * interpolated source. The normal website form owns tokens and authentication.
 * Return only a finite status: no fields, page text, URLs or credentials.
 */
return (() => {
  const result = status => ({ status });
  try {
    const trusted = url => url.protocol === 'https:' &&
      ['tcgtracking.com', 'www.tcgtracking.com'].includes(url.hostname.toLowerCase()) &&
      !url.username && !url.password && (!url.port || url.port === '443');
    const page = new URL(location.href);
    if (!trusted(page) || (typeof window === 'object' && window.top !== window) ||
        typeof document !== 'object' || document.readyState !== 'complete' || typeof submit !== 'boolean') {
      return result('unsupported');
    }
    const visible = element => {
      if (!element || element.hidden || element.disabled || element.readOnly || element.isConnected === false ||
          element.matches(':disabled') || element.closest('[inert]') || !element.getClientRects().length) return false;
      const style = getComputedStyle(element);
      return style.display !== 'none' && style.visibility !== 'hidden' && style.visibility !== 'collapse';
    };
    const text = value => String(value || '').slice(0, 256).replace(/\s+/g, ' ').trim().toLowerCase();
    const login = value => /\b(?:log[\s_-]?in|sign[\s_-]?in)\b/.test(text(value));
    const other = value => /\b(?:register|registration|sign[\s_-]?up|create[\s_-]?(?:an?[\s_-])?account|reset|recover|forgot|(?:change|new|set|update)[\s_-]?password)\b/.test(text(value));
    const safeSubmission = (form, button) => {
      const action = new URL(button.hasAttribute('formaction') ? button.formAction : form.action, page.href);
      const method = text(button.hasAttribute('formmethod') ? button.formMethod : form.method);
      return trusted(action) && action.origin === page.origin && method === 'post';
    };
    const needsVerification = form => {
      const widgets = form.querySelectorAll('iframe,.g-recaptcha,.h-captcha,.cf-turnstile');
      if (widgets.length > 32) return true;
      const challenge = Array.from(widgets).some(element => visible(element) &&
        (element.tagName.toLowerCase() !== 'iframe' || /captcha|challenges\.cloudflare\.com/i.test(element.getAttribute('src') || '')));
      const responses = form.querySelectorAll('input,textarea');
      if (responses.length > 128) return true;
      const solved = Array.from(responses).some(input =>
        ['g-recaptcha-response', 'h-captcha-response', 'cf-turnstile-response'].includes(input.name) && String(input.value || '').trim());
      return challenge && !solved;
    };
    const forms = document.querySelectorAll('form');
    if (forms.length > 32) return result('unsupported');
    const candidates = [];
    let rejectedPasswordForm = false;
    for (const form of forms) {
      const fields = form.querySelectorAll('input');
      if (fields.length > 128) return result('unsupported');
      const inputs = Array.from(fields);
      const passwords = inputs.filter(input => input.type.toLowerCase() === 'password');
      if (!passwords.some(visible)) continue;
      const metadata = [form.id, form.getAttribute('name'), form.action, page.pathname].map(text).join(' ');
      if (passwords.length !== 1 || !visible(passwords[0]) || other(metadata) ||
          text(passwords[0].autocomplete).split(' ').includes('new-password')) {
        rejectedPasswordForm = true; continue;
      }
      const buttons = Array.from(form.querySelectorAll('button,input[type="submit"]'))
        .filter(button => button.type.toLowerCase() === 'submit' && visible(button));
      const label = button => text(button.textContent || button.value || button.getAttribute('aria-label'));
      const loginButtons = buttons.filter(button => login(label(button)) && !other(label(button)));
      const button = loginButtons.length === 1 ? loginButtons[0] :
        (loginButtons.length === 0 && buttons.length === 1 && login(metadata) && !other(label(buttons[0])) ? buttons[0] : null);
      if (!button || buttons.some(item => other(label(item)))) { rejectedPasswordForm = true; continue; }
      if (!safeSubmission(form, button)) {
        rejectedPasswordForm = true; continue;
      }
      const eligible = inputs.filter(input => ['email', 'text'].includes(input.type.toLowerCase()) && visible(input));
      const named = eligible.filter(input => input.type.toLowerCase() === 'email' ||
        text(input.autocomplete).split(' ').includes('username') ||
        /(?:^|[\s_-])(?:user(?:name)?|email|login)(?:$|[\s_-])/.test(text(input.name) + ' ' + text(input.id)));
      const userField = named.length === 1 ? named[0] : (named.length === 0 && eligible.length === 1 ? eligible[0] : null);
      if (!userField || userField.form !== form || passwords[0].form !== form || button.form !== form ||
          !form.contains(userField) || !form.contains(passwords[0]) || !form.contains(button)) {
        rejectedPasswordForm = true; continue;
      }
      candidates.push({ form, button, userField, passwordField: passwords[0], verification: needsVerification(form) });
    }
    if (candidates.length !== 1) {
      if (candidates.length > 1 || rejectedPasswordForm) return result('unsupported');
      // A default probe is read-only. Explicit navigation may follow the site's
      // own unique Login link; no endpoint or query parameter is invented.
      if (typeof navigate === 'boolean' && navigate && !submit) {
        const anchors = document.querySelectorAll('a[href]');
        if (anchors.length > 256) return result('unsupported');
        const links = Array.from(anchors).filter(anchor => {
          if (!visible(anchor) || anchor.hasAttribute('download')) return false;
          const label = text(anchor.textContent || anchor.getAttribute('aria-label'));
          if (!/^(?:log[\s_-]?in|sign[\s_-]?in)$/.test(label)) return false;
          try { return trusted(new URL(anchor.href, page.href)); } catch { return false; }
        });
        if (links.length === 1) {
          location.assign(new URL(links[0].href, page.href).href);
          return result('navigating');
        }
      }
      return result('not_found');
    }
    const candidate = candidates[0];
    if (!submit) return result(candidate.verification ? 'verification_required' : 'ready');
    if (typeof username !== 'string' || !username.trim() || username.length > 512 ||
        typeof password !== 'string' || !password.length || password.length > 8192) return result('unsupported');
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
    const check = HTMLFormElement.prototype.checkValidity;
    const send = HTMLFormElement.prototype.requestSubmit;
    if (!setter || typeof check !== 'function' || typeof send !== 'function') return result('unsupported');
    for (const [field, value] of [[candidate.userField, username], [candidate.passwordField, password]]) {
      setter.call(field, value);
      field.dispatchEvent(new Event('input', { bubbles: true }));
      field.dispatchEvent(new Event('change', { bubbles: true }));
    }
    if (!safeSubmission(candidate.form, candidate.button) || !visible(candidate.userField) || !visible(candidate.passwordField) ||
        candidate.userField.form !== candidate.form || candidate.passwordField.form !== candidate.form || candidate.button.form !== candidate.form) {
      return result('unsupported');
    }
    if (needsVerification(candidate.form)) return result('verification_required');
    if (!check.call(candidate.form)) return result('unsupported');
    send.call(candidate.form, candidate.button);
    return result('submitted');
  } catch {
    return result('unsupported');
  }
})();

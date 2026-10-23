/**
 * App-level helpers shared by desktop.js and mobile.js.
 * Service access goes through the short-lived token from /newscanplus/api/token.php;
 * 503 there means the Vultr service is not configured yet (pages still work, matching waits).
 */

const GAME_KEY = 'nsp.game';
const TOKEN_SLACK_S = 60;

export function bindGamePicker(select, onChange) {
    if (!select) return () => 'tcgp:3';
    const saved = localStorage.getItem(GAME_KEY);
    if (saved && select.querySelector(`option[value="${CSS.escape(saved)}"]`)) select.value = saved;
    select.addEventListener('change', () => {
        localStorage.setItem(GAME_KEY, select.value);
        onChange?.(select.value);
    });
    return () => select.value;
}

const SYMBOL_FOLDERS = { 'tcgp:1': 'mtg', 'tcgp:2': 'yugioh', 'tcgp:3': 'pokemon', 'tcgp:85': 'pokemon' };

/** Set symbol image for a game + set abbreviation ('' when the game has no symbol set). Misses serve a 1 px image. */
export function setSymbolUrl(gameKey, abbr) {
    const folder = SYMBOL_FOLDERS[gameKey];
    const clean = String(abbr || '').toUpperCase().replace(/:/g, '_').replace(/[^A-Z0-9_-]/g, '');
    return folder && clean ? `/scan/set-symbols/${folder}/${clean}.png` : '';
}

export function setStatus(el, state, text) {
    if (!el) return;
    el.dataset.state = state;
    el.textContent = text;
}

let session = null;
let tokenScope = 'scan';

/** 'price' = anonymous public price check (/newscanplus/quick); 'scan' = signed-in desktop. */
export function useScope(scope) {
    tokenScope = scope;
    session = null;
}

export async function serviceSession(force = false) {
    const now = Date.now() / 1000;
    if (!force && session && session.exp - TOKEN_SLACK_S > now) return session;
    const url = tokenScope === 'price' ? '/newscanplus/api/token.php?scope=price' : '/newscanplus/api/token.php';
    const res = await fetch(url, { credentials: 'same-origin', cache: 'no-store' });
    if (res.status === 503) return (session = { online: false, reason: 'service not deployed yet' });
    if (!res.ok) return (session = { online: false, reason: `token error ${res.status}` });
    const body = await res.json();
    session = { online: true, token: body.token, exp: body.exp, url: body.service_url };
    return session;
}

export async function serviceFetch(path, init = {}) {
    const s = await serviceSession();
    if (!s.online) throw new Error(s.reason);
    const headers = new Headers(init.headers || {});
    headers.set('Authorization', `Bearer ${s.token}`);
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), init.timeout ?? 15000);
    try {
        const res = await fetch(s.url + path, { ...init, headers, signal: ctrl.signal });
        if (res.status === 401) {
            await serviceSession(true);
        }
        if (!res.ok) throw new Error(`${path} ${res.status}`);
        return res;
    } finally {
        clearTimeout(timer);
    }
}

export async function checkService(statusEl) {
    setStatus(statusEl, 'checking', 'checking service…');
    try {
        const s = await serviceSession(true);
        if (!s.online) {
            setStatus(statusEl, 'offline', s.reason);
            return false;
        }
        const health = await (await serviceFetch('/v1/health', { timeout: 5000 })).json();
        const refs = Object.values(health.games || {}).reduce((n, g) => n + (g.n || 0), 0);
        setStatus(statusEl, 'online', `online · ${refs.toLocaleString()} refs`);
        return true;
    } catch (err) {
        setStatus(statusEl, 'offline', 'service unreachable');
        return false;
    }
}

/**
 * Optional service check for on-device pages; never throws. The service host is contacted
 * only after token.php issued a token (503 = not configured -> no request leaves the origin).
 * When the page exposes [data-service-live="0"] (PHP nsp_service_configured() is false), this returns
 * immediately and does not call api/token.php.
 * -> {online: true, refs} | {online: false, reason, contacted}
 */
export async function probeService(timeout = 4000) {
    if (typeof document !== 'undefined') {
        const flag = document.querySelector('[data-service-live]');
        if (flag && flag.getAttribute('data-service-live') === '0') {
            return { online: false, reason: 'service not configured', contacted: false };
        }
    }
    let s;
    try {
        s = await serviceSession(true);
    } catch {
        return { online: false, reason: 'token unavailable', contacted: false };
    }
    if (!s.online) return { online: false, reason: s.reason, contacted: false };
    try {
        const health = await (await serviceFetch('/v1/health', { timeout })).json();
        const refs = Object.values(health.games || {}).reduce((n, g) => n + (g.n || 0), 0);
        return { online: true, refs };
    } catch {
        return { online: false, reason: 'service unreachable', contacted: true };
    }
}

export async function catalogDetail(refs) {
    if (!refs.length) return {};
    const res = await fetch('/newscanplus/api/detail.php', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refs }),
    });
    if (!res.ok) return {};
    return (await res.json()).items || {};
}

let importMapCache = null;

/** The page import map's `imports` (core/view.php nsp_import_map): path -> path?v=mtime. */
export function importMap() {
    if (!importMapCache) {
        const node = document.querySelector('script[type="importmap"]');
        try {
            importMapCache = node ? JSON.parse(node.textContent).imports || {} : {};
        } catch {
            importMapCache = {};
        }
    }
    return importMapCache;
}

/** Cache-busted URL for workers, scripts, and fetches that the import map does not cover. */
export function versioned(path) {
    return importMap()[path] || path;
}

export function money(v) {
    return v == null || Number.isNaN(Number(v)) ? '—' : `$${Number(v).toFixed(2)}`;
}

export function el(tag, attrs = {}, ...children) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
        if (k === 'class') node.className = v;
        else if (k.startsWith('data-') || k.startsWith('aria-') || k === 'open') node.setAttribute(k, v);
        else node[k] = v;
    }
    if (children.length === 1 && (typeof children[0] === 'string' || typeof children[0] === 'number')) {
        if (children[0] !== '') node.textContent = String(children[0]);
    } else if (children.length) {
        for (const child of children) {
            if (child == null || child === '' || child === false) continue;
            node.append(child);
        }
    }
    return node;
}

export function toast(node, text, ms = 1800) {
    if (!node) return;
    node.textContent = text;
    node.hidden = false;
    clearTimeout(node._t);
    node._t = setTimeout(() => { node.hidden = true; }, ms);
}

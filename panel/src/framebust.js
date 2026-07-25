// Clickjacking defence for the panel.
//
// The panel is a static site on GitHub Pages, which cannot set HTTP response
// headers, so its CSP is delivered by a build-time-injected `<meta
// http-equiv>` (see `panel/vite.config.js`). Per the CSP spec, `frame-ancestors`
// is *ignored* when delivered that way — browsers log "The Content Security
// Policy directive 'frame-ancestors' is ignored when delivered via a <meta>
// element" and apply nothing. So listing it there gave the appearance of
// anti-framing protection without any of the effect. This module is the real
// protection; the directive was dropped from the meta CSP rather than left to
// generate a warning that implied a guarantee we did not have.
//
// It must stay the FIRST import of `main.js`: ES module dependencies evaluate
// in source order, so throwing here aborts evaluation of the whole entry graph
// before any UI is built or any listener is attached.
//
// It refuses to run rather than busting out to the top frame. The panel holds
// passphrase entry, provider credential fields and device key-provisioning
// actions, so a framed instance must present nothing clickable at all.
// Deliberately no `top.location = ...` escape: that would make the panel an
// open-redirect gadget for anyone who frames it. The user gets a plain link and
// navigates themselves.

function isFramed() {
  try {
    return window.top !== window.self;
  } catch {
    // Reading `window.top` cross-origin throws — which is itself proof we are
    // framed by another origin. Fail closed.
    return true;
  }
}

if (isFramed()) {
  const { origin, pathname } = window.location;

  const notice = document.createElement('main');

  const heading = document.createElement('h1');
  heading.textContent = 'Blocked';

  const reason = document.createElement('p');
  reason.className = 'error';
  reason.textContent =
    'The iptvs panel refuses to run inside another site. This protects your ' +
    'sync passphrase and provider credentials from a page you did not open.';

  const escape = document.createElement('p');
  escape.append(document.createTextNode('Open it directly: '));
  const link = document.createElement('a');
  // Our own address only — never a value taken from the framing page.
  link.href = origin + pathname;
  link.target = '_blank';
  link.rel = 'noopener noreferrer';
  link.textContent = origin + pathname;
  escape.append(link);

  notice.append(heading, reason, escape);

  document.title = 'Blocked — iptvs';
  document.body.replaceChildren(notice);

  // Aborts the importing module graph, so `main.js` never evaluates.
  throw new Error('iptvs panel: refusing to run inside a frame');
}

import {platformOf, embeddedBrowser, destinations, automaticDestination} from './routing.mjs';
import {localeOf, messages} from './i18n.mjs';
const byId = id => document.getElementById(id);
function enable(id, url, label) {
  if (!url) return;
  const link = byId(id);
  link.href = url;
  link.textContent = label;
  link.classList.remove('disabled');
  link.removeAttribute('aria-disabled');
  link.hidden = false;
}
async function start() {
  const locale = localeOf(navigator.languages?.[0] || navigator.language);
  const t = messages[locale];
  document.documentElement.lang = locale;
  document.title = t.title;
  document.querySelectorAll('[data-i18n]').forEach(el => { el.textContent = t[el.dataset.i18n]; });
  byId('platforms').setAttribute('aria-label', t.platforms);
  byId('browser-help').textContent = t.browserHelp;
  byId('status').textContent = t.checking;
  byId('ios-link').textContent = t.iosPending;
  byId('android-link').textContent = t.androidPending;
  byId('android-help').textContent = t.androidHelp;
  const ua = navigator.userAgent;
  const platform = platformOf(ua, navigator.maxTouchPoints);
  const embedded = embeddedBrowser(ua);
  byId('browser-help').hidden = !embedded;
  if (platform !== 'desktop') {
    const card = byId(`${platform}-card`);
    card.classList.add('preferred');
    card.parentElement.prepend(card);
  }
  try {
    const response = await fetch('./config.json', {cache:'no-store', credentials:'omit'});
    if (!response.ok) throw new Error('configuration unavailable');
    const config = await response.json();
    const d = destinations(config);
    enable('ios-link', d.ios, t.iosButton);
    enable('android-link', d.android, t.androidButton);
    if (d.android) {
      byId('android-help').textContent = t.androidHelp;
      const a = config.android;
      byId('android-version').textContent = [a.version ? `${t.version} ${a.version}` : '', a.size_bytes ? `${t.approx} ${Math.round(a.size_bytes / 1048576)} MiB` : ''].filter(Boolean).join(' · ');
    }
    const ready = platform === 'ios' ? d.ios : platform === 'android' ? d.android : d.ios || d.android;
    byId('status').textContent = ready ? t.choose : t.pending;
    const target = automaticDestination(config, ua, navigator.maxTouchPoints, new URLSearchParams(location.search).get('manual') === '1');
    if (target) {
      byId('status').textContent = t.redirect;
      setTimeout(() => location.replace(target), 800);
    }
  } catch {
    byId('status').textContent = t.error;
  }
}
start();

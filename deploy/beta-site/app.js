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
  byId('android-group-link').textContent = t.androidGroupButton;
  byId('android-release-status').textContent = t.androidAvailability;
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
    if (config.android?.mode === 'apk') {
      document.querySelector('[data-i18n="intro"]').textContent = t.apkIntro;
      document.querySelector('[data-i18n="androidTitle"]').textContent = t.apkTitle;
      byId('android-help').textContent = t.apkHelp;
      byId('android-group-link').hidden = true;
      byId('android-link').textContent = t.apkPending;
      byId('android-release-status').textContent = t.apkAvailability;
    }
    enable('ios-link', d.ios, t.iosButton);
    enable('android-group-link', d.group, t.androidGroupButton);
    enable('android-link', d.android, config.android?.mode === 'apk' ? t.apkButton : t.androidButton);
    byId('ios-version').textContent = config.ios?.version ? `${t.version} ${config.ios.version}` : '';
    byId('ios-release-status').hidden = config.ios?.ready === true;
    byId('ios-release-status').textContent = t.iosAvailability;
    const a = config.android || {};
    byId('android-version').textContent = [a.version ? `${t.version} ${a.version}` : '', a.size_label || ''].filter(Boolean).join(' · ');
    byId('android-release-status').hidden = config.android?.ready === true;
    if (d.group) {
      byId('android-help').textContent = t.androidHelp;
      const a = config.android;
      byId('android-version').textContent = a.version ? `${t.version} ${a.version}` : '';
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

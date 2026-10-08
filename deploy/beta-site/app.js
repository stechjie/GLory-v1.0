import {platformOf, embeddedBrowser, destinations, automaticDestination} from './routing.mjs';
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
  const ua = navigator.userAgent;
  const platform = platformOf(ua, navigator.maxTouchPoints);
  const embedded = embeddedBrowser(ua);
  byId('browser-help').hidden = !embedded;
  if (platform !== 'desktop') byId(`${platform}-card`).classList.add('preferred');
  try {
    const response = await fetch('./config.json', {cache:'no-store', credentials:'omit'});
    if (!response.ok) throw new Error('configuration unavailable');
    const config = await response.json();
    const d = destinations(config);
    enable('ios-link', d.ios, '加入 TestFlight 测试');
    enable('android-link', d.android, d.group ? '2. 接受邀请并前往 Google Play' : '加入 Google Play 测试');
    if (d.group) {
      enable('group-link', d.group, '1. 加入测试群组');
      byId('group-link').target = '_blank';
      byId('group-link').rel = 'noopener noreferrer';
      byId('android-help').textContent = '先使用 Google 账号加入测试群组，再返回这里接受邀请。两步请使用同一个账号。已加入群组可直接进行第 2 步。';
    }
    const ready = platform === 'ios' ? d.ios : platform === 'android' ? d.android : d.ios || d.android;
    byId('status').textContent = ready ? '请选择下方入口加入测试。' : '测试邀请尚未开放，请稍后再来。';
    const target = automaticDestination(config, ua, navigator.maxTouchPoints, new URLSearchParams(location.search).get('manual') === '1');
    if (target) {
      byId('status').textContent = '正在前往官方测试邀请页面…';
      setTimeout(() => location.replace(target), 800);
    }
  } catch {
    byId('status').textContent = '暂时无法读取测试邀请，请稍后刷新页面。';
  }
}
start();

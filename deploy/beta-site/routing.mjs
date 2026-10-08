export function platformOf(ua = '', touchPoints = 0) {
  if (/iPhone|iPad|iPod/i.test(ua) || (/Macintosh/i.test(ua) && touchPoints > 1)) return 'ios';
  if (/Android/i.test(ua)) return 'android';
  return 'desktop';
}
export function embeddedBrowser(ua = '') {
  return /MicroMessenger|\bQQ\/|FBAN|FBAV|Instagram|Bytedance|aweme|musical_ly|TikTok|; wv\)/i.test(ua);
}
export function verifiedURL(value, kind) {
  try {
    const u = new URL(value);
    if (u.protocol !== 'https:' || u.username || u.password || u.port || u.search || u.hash) return '';
    const rules = {
      ios: ['testflight.apple.com', /^\/join\/[A-Za-z0-9]+\/?$/],
      android: ['play.google.com', /^\/apps\/(?:internaltest\/\d+|testing\/com\.glory\.game\.google)\/?$/],
      group: ['groups.google.com', /^\/g\/[a-zA-Z0-9_-]+\/?$/],
    };
    const rule = rules[kind];
    return rule && u.hostname === rule[0] && rule[1].test(u.pathname) ? u.href : '';
  } catch { return ''; }
}
export function destinations(config = {}) {
  const ios = config.ios?.ready === true ? verifiedURL(config.ios.url, 'ios') : '';
  const a = config.android || {};
  const group = verifiedURL(a.group_url, 'group');
  const modeOK = a.mode === 'open' || (a.mode === 'group' && group);
  const android = a.ready === true && modeOK ? verifiedURL(a.url, 'android') : '';
  return {ios, android, group: android && a.mode === 'group' ? group : ''};
}
export function automaticDestination(config, ua, touchPoints, manual = false) {
  if (manual || embeddedBrowser(ua)) return '';
  const d = destinations(config);
  const platform = platformOf(ua, touchPoints);
  if (platform === 'ios') return d.ios;
  // Google group membership cannot be inferred from this page. Keep both steps visible.
  if (platform === 'android' && !d.group) return d.android;
  return '';
}

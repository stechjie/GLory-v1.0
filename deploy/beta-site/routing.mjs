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
    if (u.protocol !== 'https:' || u.username || u.password || u.port || u.hash) return '';
    if (kind === 'ios') return !u.search && u.hostname === 'testflight.apple.com' && /^\/join\/[A-Za-z0-9]+\/?$/.test(u.pathname) ? u.href : '';
    if (kind === 'android') {
      return !u.search && u.hostname === 'play.google.com' && /^\/apps\/testing\/[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+\/?$/.test(u.pathname) ? u.href : '';
    }
    if (kind === 'group') {
      return !u.search && u.hostname === 'groups.google.com' && /^\/g\/[A-Za-z0-9_-]+(?:\/about)?\/?$/.test(u.pathname) ? u.href : '';
    }
    return '';
  } catch { return ''; }
}
export function destinations(config = {}) {
  const ios = config.ios?.ready === true ? verifiedURL(config.ios.url, 'ios') : '';
  const a = config.android || {};
  const group = a.mode === 'play_closed' ? verifiedURL(a.group_url, 'group') : '';
  // Keep the enrollment link available during review; Play controls eligibility.
  const android = a.mode === 'play_closed' && group ? verifiedURL(a.url, 'android') : '';
  return {ios, android, group};
}
export function automaticDestination(config, ua, touchPoints, manual = false) {
  if (manual || embeddedBrowser(ua)) return '';
  // Android stays here so the user can read installation guidance and tap Download.
  return platformOf(ua, touchPoints) === 'ios' ? destinations(config).ios : '';
}

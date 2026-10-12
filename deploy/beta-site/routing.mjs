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
      // Only a Drive file page; no arbitrary redirects or executable URL schemes.
      return u.hostname === 'drive.google.com' && /^\/file\/d\/[A-Za-z0-9_-]+\/view$/.test(u.pathname) && (!u.search || u.search === '?usp=sharing' || u.search === '?usp=drivesdk') ? u.href : '';
    }
    return '';
  } catch { return ''; }
}
export function destinations(config = {}) {
  const ios = config.ios?.ready === true ? verifiedURL(config.ios.url, 'ios') : '';
  const a = config.android || {};
  const android = a.ready === true && a.mode === 'apk' ? verifiedURL(a.url, 'android') : '';
  return {ios, android};
}
export function automaticDestination(config, ua, touchPoints, manual = false) {
  if (manual || embeddedBrowser(ua)) return '';
  // Android stays here so the user can read installation guidance and tap Download.
  return platformOf(ua, touchPoints) === 'ios' ? destinations(config).ios : '';
}

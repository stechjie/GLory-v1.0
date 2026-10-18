// Use the device/browser's primary language; non-Chinese languages default to English.
export function localeOf(language = '') {
  const tag = language.toLowerCase().replaceAll('_', '-');
  if (!/^zh(?:-|$)/.test(tag)) return 'en';
  if (tag.split('-').includes('hant')) return 'zh-Hant';
  if (tag.split('-').includes('hans')) return 'zh-Hans';
  return /(?:^|-)(tw|hk|mo)(?:-|$)/.test(tag) ? 'zh-Hant' : 'zh-Hans';
}
export const messages = {
  'zh-Hans': {
    title:'GLory · 加入游戏测试', eyebrow:'抢先体验 · 一起完善游戏', headline:'下一场对局，等你加入。',
    intro:'iPhone / iPad 通过 TestFlight 加入测试，Android 通过 Google Play 加入内部测试。', platforms:'选择测试平台',
    iosTitle:'TestFlight 测试', iosHelp:'先安装 Apple TestFlight，再接受测试邀请并安装 GLory。', iosButton:'加入 TestFlight 测试', iosPending:'测试邀请准备中',
    androidTitle:'Google Play 内部测试', androidButton:'加入 Google Play 内部测试', androidPending:'Google Play 测试入口准备中',
    androidHelp:'使用已获邀请的 Google 账号打开下方链接，点击 Accept invite（接受邀请），再点击 Download test app，前往 Google Play 安装。仅限内部测试名单中的账号；若提示未获邀请，请联系邀请你的工作人员添加账号。',
    browserHelp:'请点击右上角菜单，选择“在浏览器中打开”。iPhone 使用 Safari，Android 使用 Chrome。',
    checking:'正在检查测试入口…', choose:'请选择下方入口加入测试。', pending:'当前设备的下载入口准备中，请稍后再来。', redirect:'正在前往官方测试邀请页面…', error:'暂时无法读取测试邀请，请稍后刷新页面。',
    version:'版本', approx:'约', feedbackBefore:'测试版可能存在问题。请留意游戏内公告，并将体验反馈给邀请你的主播，或', feedbackLink:'加入官方反馈群', feedbackAfter:'进行反馈。', footer:'GLory · 期待与你相遇'
  },
  'zh-Hant': {
    title:'GLory · 加入遊戲測試', eyebrow:'搶先體驗 · 一起完善遊戲', headline:'下一場對局，等你加入。',
    intro:'iPhone / iPad 透過 TestFlight 加入測試，Android 透過 Google Play 加入內部測試。', platforms:'選擇測試平台',
    iosTitle:'TestFlight 測試', iosHelp:'先安裝 Apple TestFlight，再接受測試邀請並安裝 GLory。', iosButton:'加入 TestFlight 測試', iosPending:'測試邀請準備中',
    androidTitle:'Google Play 內部測試', androidButton:'加入 Google Play 內部測試', androidPending:'Google Play 測試入口準備中',
    androidHelp:'使用已獲邀請的 Google 帳號開啟下方連結，點擊 Accept invite（接受邀請），再點擊 Download test app，前往 Google Play 安裝。僅限內部測試名單中的帳號；若提示未獲邀請，請聯絡邀請你的工作人員加入帳號。',
    browserHelp:'請點擊右上角選單，選擇「在瀏覽器中開啟」。iPhone 使用 Safari，Android 使用 Chrome。',
    checking:'正在檢查測試入口…', choose:'請選擇下方入口加入測試。', pending:'目前裝置的下載入口準備中，請稍後再來。', redirect:'正在前往官方測試邀請頁面…', error:'暫時無法讀取測試邀請，請稍後重新整理頁面。',
    version:'版本', approx:'約', feedbackBefore:'測試版可能存在問題。請留意遊戲內公告，並將體驗回饋給邀請你的實況主，或', feedbackLink:'加入官方回饋群', feedbackAfter:'提供回饋。', footer:'GLory · 期待與你相遇'
  },
  en: {
    title:'GLory · Join the Playtest', eyebrow:'EARLY ACCESS · HELP SHAPE THE GAME', headline:'Your next match awaits.',
    intro:'Join on iPhone or iPad through TestFlight, or join Android internal testing through Google Play.', platforms:'Choose your platform',
    iosTitle:'TestFlight Playtest', iosHelp:'Install Apple TestFlight, then accept the invitation and install GLory.', iosButton:'Join on TestFlight', iosPending:'Test invitation coming soon',
    androidTitle:'Google Play Internal Testing', androidButton:'Join on Google Play', androidPending:'Google Play invitation coming soon',
    androidHelp:'Open the link below with your invited Google account. Select Accept invite, then Download test app to install through Google Play. Only accounts on the internal testing list can join. If you are not invited, contact the person who invited you to have your account added.',
    browserHelp:'Open the menu in the top-right corner and choose Open in Browser. Use Safari on iPhone or Chrome on Android.',
    checking:'Checking playtest availability…', choose:'Choose your platform below to join.', pending:'Downloads for your device are not ready yet. Please check back later.', redirect:'Opening the official TestFlight invitation…', error:'Unable to load the playtest links. Please refresh the page and try again.',
    version:'Version', approx:'About', feedbackBefore:'This test version may have bugs. Check the in-game announcements and share feedback with the streamer who invited you, or ', feedbackLink:'join our official feedback community', feedbackAfter:' on Discord.', footer:'GLory · See you in the game'
  }
};

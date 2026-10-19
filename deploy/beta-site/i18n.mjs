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
    apkPending:'Android 新版准备中', apkAvailability:'新版安装包正在上传，验证完成后开放下载。', apkIntro:'iPhone / iPad 通过 TestFlight 加入测试，Android 直接下载安装包。', apkTitle:'Android 测试版下载', apkButton:'下载 GLory Android 安装包', apkHelp:'下载 APK 后打开并安装。如系统询问，请允许当前浏览器安装应用。请安装 0.0.25 或更新版本，旧版本无法连接当前对局服务器。', iosAvailability:'新版 TestFlight 正在准备中，请等待更新至 0.0.25 或更新版本。旧版本无法连接当前对局服务器。',
    title:'GLory · 加入游戏测试', eyebrow:'抢先体验 · 一起完善游戏', headline:'下一场对局，等你加入。',
    intro:'iPhone / iPad 通过 TestFlight 加入测试，Android 加入测试群组后通过 Google Play 安装。', platforms:'选择测试平台',
    iosTitle:'TestFlight 测试', iosHelp:'先安装 Apple TestFlight，再接受测试邀请并安装 GLory。', iosButton:'加入 TestFlight 测试', iosPending:'测试邀请准备中',
    androidTitle:'Google Play 封闭测试', androidGroupButton:'① 加入群组', androidButton:'② 加入测试', androidPending:'② 加入测试（准备中）', androidAvailability:'测试版本通过 Google 审核并发布后即可下载安装，目前可先加入群组。',
    androidHelp:'如果尚未加入 Google Play 测试群组，请先点击“① 加入群组”并完成加入。已加入的用户可点击“② 加入测试”，使用同一个 Google 账号报名并从 Google Play 安装。',
    browserHelp:'请点击右上角菜单，选择“在浏览器中打开”。iPhone 使用 Safari，Android 使用 Chrome。',
    checking:'正在检查测试入口…', choose:'请选择下方入口加入测试。', pending:'当前设备的下载入口准备中，请稍后再来。', redirect:'正在前往官方测试邀请页面…', error:'暂时无法读取测试邀请，请稍后刷新页面。',
    version:'版本', approx:'约', feedbackBefore:'测试版可能存在问题。请留意游戏内公告，并将体验反馈给邀请你的主播，或', feedbackLink:'加入官方反馈群', feedbackAfter:'进行反馈。', footer:'GLory · 期待与你相遇'
  },
  'zh-Hant': {
    apkPending:'Android 新版準備中', apkAvailability:'新版安裝包正在上傳，驗證完成後開放下載。', apkIntro:'iPhone / iPad 透過 TestFlight 加入測試，Android 直接下載安裝包。', apkTitle:'Android 測試版下載', apkButton:'下載 GLory Android 安裝包', apkHelp:'下載 APK 後開啟並安裝。如系統詢問，請允許目前瀏覽器安裝應用程式。請安裝 0.0.25 或更新版本，舊版本無法連線至目前的對局伺服器。', iosAvailability:'新版 TestFlight 正在準備中，請等待更新至 0.0.25 或更新版本。舊版本無法連線至目前的對局伺服器。',
    title:'GLory · 加入遊戲測試', eyebrow:'搶先體驗 · 一起完善遊戲', headline:'下一場對局，等你加入。',
    intro:'iPhone / iPad 透過 TestFlight 加入測試，Android 加入測試群組後透過 Google Play 安裝。', platforms:'選擇測試平台',
    iosTitle:'TestFlight 測試', iosHelp:'先安裝 Apple TestFlight，再接受測試邀請並安裝 GLory。', iosButton:'加入 TestFlight 測試', iosPending:'測試邀請準備中',
    androidTitle:'Google Play 封閉測試', androidGroupButton:'① 加入群組', androidButton:'② 加入測試', androidPending:'② 加入測試（準備中）', androidAvailability:'測試版本通過 Google 審核並發布後即可下載安裝，目前可先加入群組。',
    androidHelp:'如果尚未加入 Google Play 測試群組，請先點擊「① 加入群組」並完成加入。已加入的使用者可點擊「② 加入測試」，使用同一個 Google 帳號報名並從 Google Play 安裝。',
    browserHelp:'請點擊右上角選單，選擇「在瀏覽器中開啟」。iPhone 使用 Safari，Android 使用 Chrome。',
    checking:'正在檢查測試入口…', choose:'請選擇下方入口加入測試。', pending:'目前裝置的下載入口準備中，請稍後再來。', redirect:'正在前往官方測試邀請頁面…', error:'暫時無法讀取測試邀請，請稍後重新整理頁面。',
    version:'版本', approx:'約', feedbackBefore:'測試版可能存在問題。請留意遊戲內公告，並將體驗回饋給邀請你的實況主，或', feedbackLink:'加入官方回饋群', feedbackAfter:'提供回饋。', footer:'GLory · 期待與你相遇'
  },
  en: {
    apkPending:'New Android build coming soon', apkAvailability:'The new installer is being uploaded. Downloads will open after verification.', apkIntro:'Join on iPhone or iPad through TestFlight, or download the Android installer directly.', apkTitle:'Android Playtest Download', apkButton:'Download GLory for Android', apkHelp:'Download and open the APK to install. If prompted, allow this browser to install apps. Install version 0.0.25 or later; older versions cannot connect to the current match server.', iosAvailability:'The new TestFlight build is being prepared. Please wait for version 0.0.25 or later; older versions cannot connect to the current match server.',
    title:'GLory · Join the Playtest', eyebrow:'EARLY ACCESS · HELP SHAPE THE GAME', headline:'Your next match awaits.',
    intro:'Join on iPhone or iPad through TestFlight, or join the testing group and install on Android through Google Play.', platforms:'Choose your platform',
    iosTitle:'TestFlight Playtest', iosHelp:'Install Apple TestFlight, then accept the invitation and install GLory.', iosButton:'Join on TestFlight', iosPending:'Test invitation coming soon',
    androidTitle:'Google Play Closed Testing', androidGroupButton:'1. Join the group', androidButton:'2. Join the test', androidPending:'2. Join the test (coming soon)', androidAvailability:'Installation will be available after Google approves and publishes the test release. You can join the group now.',
    androidHelp:'If you have not joined the Google Play testing group, select 1. Join the group and complete registration first. Group members can select 2. Join the test, enroll with the same Google account, and install through Google Play.',
    browserHelp:'Open the menu in the top-right corner and choose Open in Browser. Use Safari on iPhone or Chrome on Android.',
    checking:'Checking playtest availability…', choose:'Choose your platform below to join.', pending:'Downloads for your device are not ready yet. Please check back later.', redirect:'Opening the official TestFlight invitation…', error:'Unable to load the playtest links. Please refresh the page and try again.',
    version:'Version', approx:'About', feedbackBefore:'This test version may have bugs. Check the in-game announcements and share feedback with the streamer who invited you, or ', feedbackLink:'join our official feedback community', feedbackAfter:' on Discord.', footer:'GLory · See you in the game'
  }
};

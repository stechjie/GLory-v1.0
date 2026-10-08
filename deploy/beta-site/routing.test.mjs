import test from 'node:test';
import assert from 'node:assert/strict';
import {platformOf, automaticDestination, destinations, verifiedURL} from './routing.mjs';
const config = {ios:{ready:true,url:'https://testflight.apple.com/join/Fixture01'},android:{ready:true,mode:'open',url:'https://play.google.com/apps/testing/com.glory.game.google'}};
test('iPhone and desktop-mode iPad route to TestFlight', () => {
  assert.equal(automaticDestination(config, 'iPhone', 1), config.ios.url);
  assert.equal(automaticDestination(config, 'Macintosh', 5), config.ios.url);
  assert.equal(platformOf('Macintosh', 0), 'desktop');
});
test('Android routes only when public access is ready', () => {
  assert.equal(automaticDestination(config, 'Android', 1), config.android.url);
  assert.equal(automaticDestination({...config,android:{...config.android,ready:false}}, 'Android', 1), '');
  assert.equal(destinations({...config,android:{...config.android,mode:'internal'}}).android, '');
});
test('group onboarding keeps both steps visible; never assumes membership', () => {
  const groupConfig={...config,android:{...config.android,mode:'group',group_url:'https://groups.google.com/g/glory-fixture'}};
  assert.ok(destinations(groupConfig).android);
  assert.equal(automaticDestination(groupConfig,'Android',1), '');
  assert.equal(destinations({...groupConfig,android:{...groupConfig.android,group_url:''}}).android,'');
});
test('embedded browser, desktop and manual preview do not auto-redirect', () => {
  for(const ua of ['iPhone MicroMessenger','Android; wv)','iPhone aweme','Windows NT']) assert.equal(automaticDestination(config,ua,1),'');
  assert.equal(automaticDestination(config,'iPhone',1,true),'');
});
test('fail closed without a verified destination, reject external redirects', () => {
  assert.equal(automaticDestination({},'iPhone',1),'');
  for (const url of ['javascript:alert(1)','https://testflight.apple.com.evil.test/join/a','https://evil.test/join/a','https://x@testflight.apple.com/join/a','https://testflight.apple.com/join/a?redirect=evil']) assert.equal(verifiedURL(url,'ios'),'');
});

import test from 'node:test';
import assert from 'node:assert/strict';
import {platformOf, automaticDestination, destinations, verifiedURL} from './routing.mjs';
const config={ios:{ready:true,url:'https://testflight.apple.com/join/Fixture01'},android:{ready:true,mode:'apk',url:'https://drive.google.com/file/d/FixtureApk123/view'}};
test('iPhone and desktop-mode iPad keep TestFlight',()=>{
 assert.equal(automaticDestination(config,'iPhone',1),config.ios.url);
 assert.equal(automaticDestination(config,'Macintosh',5),config.ios.url);
 assert.equal(platformOf('Macintosh',0),'desktop');
});
test('Android offers APK only after readiness; explicit click keeps instructions visible',()=>{
 assert.equal(destinations(config).android,config.android.url);
 assert.equal(automaticDestination(config,'Android',1),'');
 assert.equal(destinations({...config,android:{...config.android,ready:false}}).android,'');
 assert.equal(destinations({...config,android:{...config.android,mode:'group'}}).android,'');
});
test('embedded and manual browsers never redirect',()=>{
 for(const ua of ['iPhone MicroMessenger','Android; wv)','iPhone aweme','Windows NT']) assert.equal(automaticDestination(config,ua,1),'');
 assert.equal(automaticDestination(config,'iPhone',1,true),'');
});
test('reject arbitrary redirects and old store links',()=>{
 for(const url of ['javascript:alert(1)','https://drive.google.com.evil.test/file/d/a/view','https://user@drive.google.com/file/d/a/view','https://drive.google.com/file/d/a/view?redirect=evil','https://play.google.com/apps/testing/com.glory.game.google','http://drive.google.com/file/d/a/view']) assert.equal(verifiedURL(url,'android'),'');
 assert.equal(verifiedURL(config.android.url+'?usp=sharing','android'),config.android.url+'?usp=sharing');
 assert.equal(verifiedURL(config.ios.url+'?redirect=evil','ios'),'');
 assert.equal(automaticDestination({},'iPhone',1),'');
});

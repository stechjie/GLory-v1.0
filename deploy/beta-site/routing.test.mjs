import test from 'node:test';
import assert from 'node:assert/strict';
import {platformOf, automaticDestination, destinations, verifiedURL} from './routing.mjs';
const config={ios:{ready:true,url:'https://testflight.apple.com/join/Fixture01'},android:{ready:true,mode:'play_closed',group_url:'https://groups.google.com/g/glorygame/about',url:'https://play.google.com/apps/testing/com.glory.game.google'}};
test('iPhone and desktop-mode iPad keep TestFlight',()=>{
 assert.equal(automaticDestination(config,'iPhone',1),config.ios.url);
 assert.equal(automaticDestination(config,'Macintosh',5),config.ios.url);
 assert.equal(platformOf('Macintosh',0),'desktop');
});
test('Android group stays available while the closed release is pending',()=>{
 assert.equal(destinations(config).android,config.android.url);
 assert.equal(automaticDestination(config,'Android',1),'');
 assert.equal(destinations({...config,android:{...config.android,ready:false}}).android,config.android.url);
 assert.equal(destinations({...config,android:{...config.android,mode:'apk'}}).android,'');
});
test('embedded and manual browsers never redirect',()=>{
 for(const ua of ['iPhone MicroMessenger','Android; wv)','iPhone aweme','Windows NT']) assert.equal(automaticDestination(config,ua,1),'');
 assert.equal(automaticDestination(config,'iPhone',1,true),'');
});
test('reject arbitrary redirects and shared APK links',()=>{
 for(const url of ['javascript:alert(1)','https://drive.google.com.evil.test/file/d/a/view','https://user@drive.google.com/file/d/a/view','https://drive.google.com/file/d/a/view?redirect=evil','https://play.google.com/apps/internaltest/1234567890123456789','http://drive.google.com/file/d/a/view','https://drive.google.com/file/d/a/view','https://play.google.com.evil.test/apps/internaltest/123','https://play.google.com/apps/internaltest/123?redirect=evil']) assert.equal(verifiedURL(url,'android'),'');
 assert.equal(verifiedURL(config.android.url+'?usp=sharing','android'),'');
 assert.equal(verifiedURL(config.ios.url+'?redirect=evil','ios'),'');
 assert.equal(automaticDestination({},'iPhone',1),'');
});

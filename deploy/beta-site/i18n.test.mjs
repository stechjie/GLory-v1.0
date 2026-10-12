import test from 'node:test';
import assert from 'node:assert/strict';
import {localeOf, messages} from './i18n.mjs';
test('Chinese language, region and explicit script preferences', () => {
  for (const tag of ['zh','zh-CN','zh-SG','zh-Hans','zh-Hans-HK']) assert.equal(localeOf(tag),'zh-Hans');
  for (const tag of ['zh-TW','zh-HK','zh-MO','zh-Hant','zh-Hant-CN','ZH_tw']) assert.equal(localeOf(tag),'zh-Hant');
  for (const tag of ['en-US','fr','ja','ko','', 'zhx']) assert.equal(localeOf(tag),'en');
});
test('All locales translate the same UI messages', () => {
  const keys=Object.keys(messages.en).sort();
  for (const m of Object.values(messages)) {
    assert.deepEqual(Object.keys(m).sort(),keys);
    for(const value of Object.values(m)) assert.ok(value.trim());
  }
});

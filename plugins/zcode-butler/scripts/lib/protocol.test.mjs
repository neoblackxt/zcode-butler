// lib/protocol 单测:构建器 + 校验器(node --test,零依赖)
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  PROTOCOL_VERSION, ringOf, mcpRingOf, keyCardOf, newsCardOf, newsStateOf, modelCardOf,
  emptyProtocol, validateProtocol,
} from './protocol.mjs';

test('emptyProtocol:骨架合法且通过校验', () => {
  const p = emptyProtocol();
  assert.equal(p.protocolVersion, PROTOCOL_VERSION);
  assert.deepEqual(p.account, { fiveHour: null, weekly: null, mcpMonthly: null, peakNow: false,
    dayUsage: null, modelsToday: [], modelsWeek: [] });
  assert.deepEqual(validateProtocol(p), []);
});

test('modelCardOf:modelSummaryList 项/协议项双兼容,数值清洗', () => {
  assert.deepEqual(modelCardOf({ modelName: 'GLM-5.3', totalTokens: '145822480' }), { name: 'GLM-5.3', tokens: 145822480 });
  assert.deepEqual(modelCardOf({ name: 'GLM-4.6', tokens: 42 }), { name: 'GLM-4.6', tokens: 42 });
  assert.deepEqual(modelCardOf(null), { name: '', tokens: 0 });
});

test('ringOf/mcpRingOf:数值清洗 + tools 三字段兜底', () => {
  const r = ringOf({ pct: '42.6', used: '100', limit: 240, resetAt: 1790000000000 });
  assert.equal(r.pct, 43); // 四舍五入
  assert.equal(r.used, 100);
  assert.equal(r.status, 'ok');
  const m = mcpRingOf({ pct: 11, used: 110, limit: 1000, resetAt: 0, tools: { webSearch: 3, 别的: 9 } });
  assert.deepEqual(m.tools, { webSearch: 3, webReader: 0, zread: 0 }); // 未知工具字段丢弃
});

test('keyCardOf:协议卡字段齐 + provider/incomplete 透传 + error 可选', () => {
  const k = keyCardOf({
    id: 'k1', name: '主力', tier: 'PRO', tail: 'A1B2', pct: 42.4,
    usedWeighted: 7.3e8, quota: 17.5e8, peak: 6.1e8, offpeak: 2.6e8,
    resetDate: '2026-09-30', status: 'ok', provider: 'zai', incomplete: true,
  });
  assert.equal(k.pct, 42);
  assert.equal(k.provider, 'zai');
  assert.equal(k.incomplete, true);
  assert.equal('error' in k, false);
  const bad = keyCardOf({ id: 'k2', name: 'x', tier: '', tail: '', pct: 0, usedWeighted: 0, quota: 0, peak: 0, offpeak: 0, resetDate: '', status: 'error', error: 'HTTP 401', provider: 'other' });
  assert.equal(bad.status, 'error');
  assert.equal(bad.error, 'HTTP 401');
  assert.equal(bad.provider, 'bigmodel'); // 非 zai 一律 bigmodel
});

test('newsStateOf:unread 计数 + 条目 read 标记', () => {
  const items = [newsCardOf({ id: 'n1', title: 'a' }), newsCardOf({ id: 'n2', title: 'b' })];
  const st = newsStateOf(items, ['n1']);
  assert.equal(st.unread, 1);
  assert.equal(st.items[0].read, true);
  assert.equal(st.items[1].read, false);
});

test('validateProtocol:合法全量载荷通过', () => {
  const p = emptyProtocol();
  p.account.fiveHour = ringOf({ pct: 3, used: 0, limit: 0, resetAt: 1789138996705 });
  p.account.mcpMonthly = mcpRingOf({ pct: 11, used: 110, limit: 1000, resetAt: 1790071443998, tools: { webSearch: 104 } });
  p.keys = [keyCardOf({ id: 'k1', name: '主力', tier: 'PRO', tail: 'A1B2', pct: 42, usedWeighted: 7, quota: 10, peak: 1, offpeak: 2, resetDate: '2026-09-30', status: 'ok' })];
  p.news = newsStateOf([newsCardOf({ id: 'n1', title: 't' })], []);
  p.errors = [{ module: 'watch', message: 'x' }];
  assert.deepEqual(validateProtocol(p), []);
});

test('validateProtocol:各部位结构破坏都被点名', () => {
  assert.ok(validateProtocol(null).length >= 1);
  const bad = emptyProtocol();
  bad.protocolVersion = 99;
  bad.fetchedAt = 123;
  bad.account = { fiveHour: 'x', weekly: null, mcpMonthly: null, peakNow: 'no' };
  bad.keys = [{ id: 1 }];
  bad.news = { unread: 'x', items: {} };
  bad.errors = ['x'];
  const errs = validateProtocol(bad);
  assert.ok(errs.some((e) => e.includes('protocolVersion')));
  assert.ok(errs.some((e) => e.includes('fetchedAt')));
  assert.ok(errs.some((e) => e.includes('account.fiveHour')));
  assert.ok(errs.some((e) => e.includes('peakNow')));
  assert.ok(errs.some((e) => e.includes('keys[0]')));
  assert.ok(errs.some((e) => e.includes('news.unread')));
  assert.ok(errs.some((e) => e.includes('news.items')));
  assert.ok(errs.some((e) => e.includes('errors[0]')));
});

test('validateProtocol:环为 null 合法(模块降级语义)', () => {
  const p = emptyProtocol();
  p.errors = [{ module: 'usage', message: '网络错误' }];
  assert.deepEqual(validateProtocol(p), []);
});

test('validateProtocol:v0.2.12 弹框明细三字段(缺省容忍;类型错逐项点名)', () => {
  const p = emptyProtocol();
  p.account.dayUsage = { total: { calls: 1, tokens: 'x' }, peak: null, offPeak: { calls: 0, tokens: 0 } };
  p.account.modelsToday = [{ name: 1, tokens: 2 }];
  p.account.modelsWeek = 'x';
  const errs = validateProtocol(p);
  assert.ok(errs.some((e) => e.includes('dayUsage.total.tokens')));
  assert.ok(errs.some((e) => e.includes('dayUsage.peak')));
  assert.ok(errs.some((e) => e.includes('modelsToday[0]')));
  assert.ok(errs.some((e) => e.includes('modelsWeek')));
  // 合法全量形态通过
  const q = emptyProtocol();
  q.account.dayUsage = { total: { calls: 1, tokens: 10 }, peak: { calls: 0, tokens: 0 }, offPeak: { calls: 1, tokens: 10 } };
  q.account.modelsToday = [{ name: 'GLM-5.3', tokens: 100 }];
  q.account.modelsWeek = [];
  assert.deepEqual(validateProtocol(q), []);
  // 缺省容忍(旧载荷无三字段)
  const r = emptyProtocol();
  delete r.account.dayUsage;
  delete r.account.modelsToday;
  delete r.account.modelsWeek;
  assert.deepEqual(validateProtocol(r), []);
});

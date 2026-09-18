// 文件职责：插件侧宿主桥接客户端——以 stdio 承载 JSON-RPC 2.0，帧格式与宿主 UI Bridge 一致
// 说明：本客户端随插件打包（插件之间不共享代码，宿主也不提供全局依赖），因此各插件各存一份
'use strict';

const readline = require('readline');

/** 创建插件侧桥接；services 形如 { 'document.convert': async (input, ctx) => result } */
function createBridge({ services, onActivate, onDeactivate }) {
  let seq = 0;                                      // 向宿主发起调用时的请求序号
  const pending = new Map();                        // 请求 ID → 等待中的 Promise
  const cancelled = new Set();                      // 已收到取消通知的 callId

  const write = (msg) => process.stdout.write(JSON.stringify(msg) + '\n');

  // 向宿主发起 host.* 调用
  function callHost(method, params) {
    const id = ++seq;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      write({ jsonrpc: '2.0', id, method, params: params || {} });
    });
  }

  // 传给服务实现的上下文：只能用宿主签发的能力，不能自行扩权
  const ctx = {
    callHost,
    isCancelled: (callId) => cancelled.has(callId),
  };

  // 处理宿主的入站请求（plugin.activate / plugin.service.invoke）
  async function handleRequest(msg) {
    const { id, method, params } = msg;
    try {
      let result;
      if (method === 'plugin.activate') {
        if (onActivate) await onActivate(params, ctx);
        result = { activated: true, installationId: params.installationId };
      } else if (method === 'plugin.service.invoke') {
        const fn = services[params.service];
        if (!fn) throw new Error(`未实现的服务：${params.service}`);
        result = await fn(params.input || {}, Object.assign({}, ctx, { callId: params.callId }));
      } else {
        throw new Error(`未知的入站方法：${method}`);
      }
      write({ jsonrpc: '2.0', id, result: result === undefined ? {} : result });
    } catch (error) {
      // 业务错误码由插件显式给出时沿用，否则按提供者不可用上报
      write({
        jsonrpc: '2.0',
        id,
        error: {
          code: -32000,
          message: String((error && error.message) || error),
          data: { code: (error && error.code) || 'PROVIDER_UNAVAILABLE' },
        },
      });
    }
  }

  // 处理宿主发来的通知（plugin.task.cancel / plugin.deactivate）
  function handleNotification(msg) {
    if (msg.method === 'plugin.task.cancel') {
      cancelled.add(msg.params && msg.params.callId);
    } else if (msg.method === 'plugin.deactivate') {
      if (onDeactivate) onDeactivate(msg.params || {});
      process.exit(0);
    }
  }

  // 处理宿主对我们 callHost 的响应
  function settle(msg) {
    const waiting = pending.get(msg.id);
    if (!waiting) return;
    pending.delete(msg.id);
    if (msg.error) {
      const code = (msg.error.data && msg.error.data.code) || 'CAPABILITY_DENIED';
      const err = new Error(msg.error.message);
      err.code = code;
      waiting.reject(err);
    } else {
      waiting.resolve(msg.result || {});
    }
  }

  // 逐行读取宿主报文：带 method 的入站请求/通知，带 id 的响应
  readline.createInterface({ input: process.stdin }).on('line', (line) => {
    const text = line.trim();
    if (!text) return;
    let msg;
    try {
      msg = JSON.parse(text);
    } catch (e) {
      return;                                       // 非法报文直接忽略，不影响后续通信
    }
    if (msg.method && msg.id !== undefined) handleRequest(msg);
    else if (msg.method) handleNotification(msg);
    else settle(msg);
  });
}

module.exports = { createBridge };

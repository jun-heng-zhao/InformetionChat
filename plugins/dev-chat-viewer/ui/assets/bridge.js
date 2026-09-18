// 文件职责：插件 UI 侧桥接客户端——只使用宿主注入的受信通道，不使用 postMessage('*')
// 说明：宿主为每个安装创建独立 WebView 与独立通道；插件无法通过子框架或任意窗口冒充调用身份
(function (global) {
  'use strict';

  const pending = new Map();   // 请求 ID → 等待中的 Promise
  let channel = null;          // 宿主注入的传输对象，必须实现 send()
  let seq = 0;                 // 请求序号

  // 宿主在页面加载后注入传输通道；未注入前任何调用都会被拒绝
  function attach(transport) {
    if (!transport || typeof transport.send !== 'function') {
      throw new Error('宿主通道不合法：必须实现 send()');
    }
    channel = transport;
  }

  // 发起 host.* 调用
  function rpc(method, params) {
    if (!channel) return Promise.reject(new Error('宿主通道尚未建立'));
    const id = ++seq;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      channel.send({ jsonrpc: '2.0', id, method, params: params || {} });
    });
  }

  // 处理宿主下发的报文：可能是响应，也可能是像 plugin.deactivate 这样的入站方法
  function handleIncoming(message) {
    if (!message) return;
    if (message.method) {
      if (message.method === 'plugin.deactivate') {
        document.body.dataset.state = 'deactivated';
      }
      return;
    }
    const waiting = pending.get(message.id);
    if (!waiting) return;
    pending.delete(message.id);
    if (message.error) {
      const error = new Error(message.error.message);
      error.code = (message.error.data && message.error.data.code) || 'UNKNOWN';
      waiting.reject(error);
    } else {
      waiting.resolve(message.result || {});
    }
  }

  // 握手：拿到协议版本、工作区摘要与已批准能力
  function handshake(requestedCapabilities) {
    return rpc('host.handshake', { uiBridge: '1.2', requestedCapabilities: requestedCapabilities || [] });
  }

  global.InformetionBridge = { attach, rpc, handshake, handleIncoming };
})(window);

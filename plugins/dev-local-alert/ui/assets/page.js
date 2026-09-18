// 文件职责：本地测试提醒页面逻辑——发布与撤回，等级判定交给宿主
'use strict';

(function () {
  const statusEl = document.getElementById('status');
  const publishBtn = document.getElementById('publish');
  const withdrawBtn = document.getElementById('withdraw');
  const categoryEl = document.getElementById('category');
  const levelEl = document.getElementById('level');

  let lastEvent = null;      // 上次发布的事件，供撤回使用

  const setStatus = (text) => { statusEl.textContent = text; };

  async function boot() {
    try {
      const info = await window.InformetionBridge.handshake(['notification.publish']);
      statusEl.textContent = `已连接宿主：uiBridge ${info.uiBridge}，平台 ${info.platform}`;
    } catch (error) {
      statusEl.textContent = `握手失败：${error.message}`;
    }
  }

  publishBtn.onclick = async () => {
    publishBtn.disabled = true;
    try {
      // 事件 ID 使用当前时间戳，保证新事件不会被去重逻辑当成重放
      const eventId = `web-${Date.now()}`;
      const called = await window.InformetionBridge.rpc('host.service.call', {
        service: 'alert.notify-test',
        versionRange: '^1.0.0',
        input: {
          category: categoryEl.value,
          eventId,
          revision: 1,
          requestedLevel: levelEl.value,
          title: '本地测试提醒',
          body: '这是一条用户主动触发的本地测试事件，不对应任何真实预警源。',
          expiresInSeconds: 60,
        },
      });

      let task = await window.InformetionBridge.rpc('host.task.get', { taskId: called.taskId });
      for (let i = 0; (task.state === 'queued' || task.state === 'running') && i < 100; i++) {
        await new Promise((resolve) => setTimeout(resolve, 20));
        task = await window.InformetionBridge.rpc('host.task.get', { taskId: called.taskId });
      }
      if (task.state !== 'succeeded') throw new Error(`任务未成功：${task.state}`);

      const out = task.output;
      const downgraded = out.effectiveLevel !== levelEl.value;
      setStatus(
        `请求等级 ${levelEl.value} → 实际等级 ${out.effectiveLevel}，状态 ${out.state}` +
          (out.reason ? `\n原因：${out.reason}` : '') +
          (downgraded ? '\n（未授权等级已被宿主降级，插件无法自行提升）' : '')
      );

      lastEvent = { eventId, revision: 1 };
      withdrawBtn.disabled = false;
    } catch (error) {
      setStatus(`发布失败：${error.message}（${error.code || 'UNKNOWN'}）`);
    } finally {
      publishBtn.disabled = false;
    }
  };

  withdrawBtn.onclick = async () => {
    if (!lastEvent) return;
    try {
      const result = await window.InformetionBridge.rpc('host.notification.withdraw', {
        eventId: lastEvent.eventId,
        revision: lastEvent.revision + 1,
      });
      setStatus(`已撤回：${result.notificationId}，状态 ${result.state}`);
    } catch (error) {
      setStatus(`撤回失败：${error.message}（${error.code || 'UNKNOWN'}）`);
    }
  };

  boot();
})();

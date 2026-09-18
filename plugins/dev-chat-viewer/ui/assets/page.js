// 文件职责：归档查看器页面逻辑——演示插件间调用与结果句柄传递
'use strict';

(function () {
  const statusEl = document.getElementById('status');
  const previewEl = document.getElementById('preview');
  const saveBtn = document.getElementById('save');
  const pickBtn = document.getElementById('pick');
  const formatEl = document.getElementById('format');

  let resultHandle = null;   // 本插件自己服务的结果句柄

  const setStatus = (text) => { statusEl.textContent = text; };

  async function boot() {
    try {
      const info = await window.InformetionBridge.handshake(['file.pick', 'file.read', 'file.save', 'service.call']);
      setStatus(`已连接宿主：uiBridge ${info.uiBridge}，平台 ${info.platform}`);
    } catch (error) {
      setStatus(`握手失败：${error.message}`);
    }
  }

  pickBtn.onclick = async () => {
    pickBtn.disabled = true;
    try {
      const picked = await window.InformetionBridge.rpc('host.file.pick', { purpose: '选择要导出的聊天归档' });

      // 调用本插件自己的 archive.export；它内部再调用已绑定的 document.convert
      const called = await window.InformetionBridge.rpc('host.service.call', {
        service: 'archive.export',
        versionRange: '^1.0.0',
        input: { source: `resource:${picked.handle}`, targetFormat: formatEl.value },
      });

      let task = await window.InformetionBridge.rpc('host.task.get', { taskId: called.taskId });
      for (let i = 0; (task.state === 'queued' || task.state === 'running') && i < 200; i++) {
        await new Promise((resolve) => setTimeout(resolve, 20));
        task = await window.InformetionBridge.rpc('host.task.get', { taskId: called.taskId });
      }
      if (task.state !== 'succeeded') throw new Error(`任务未成功：${task.state}`);

      resultHandle = task.output.result;
      const chunk = await window.InformetionBridge.rpc('host.resource.read', { handle: resultHandle.replace('resource:', ''), offset: 0 });
      previewEl.value = new TextDecoder().decode(Uint8Array.from(atob(chunk.bytes), (c) => c.charCodeAt(0)));
      saveBtn.disabled = false;
      setStatus(`导出完成，由 ${task.output.convertedBy} 转换，共 ${task.output.messageCount} 条消息。`);
    } catch (error) {
      setStatus(`导出失败：${error.message}（${error.code || 'UNKNOWN'}）`);
    } finally {
      pickBtn.disabled = false;
    }
  };

  saveBtn.onclick = async () => {
    try {
      const saved = await window.InformetionBridge.rpc('host.file.save', {
        handle: resultHandle.replace('resource:', ''),
        suggestedName: 'archive-export.md',
      });
      setStatus(`已保存：${saved.label}`);
    } catch (error) {
      setStatus(`保存失败：${error.message}（${error.code || 'UNKNOWN'}）`);
    }
  };

  boot();
})();

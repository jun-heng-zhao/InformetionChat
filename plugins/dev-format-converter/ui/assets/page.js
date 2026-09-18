// 文件职责：格式转换页面逻辑——按钮与 Agent 调用的是同一个 document.convert 服务
'use strict';

(function () {
  const statusEl = document.getElementById('status');
  const previewEl = document.getElementById('preview');
  const saveBtn = document.getElementById('save');
  const pickBtn = document.getElementById('pick');
  const formatEl = document.getElementById('format');

  let resultHandle = null;   // 最近一次转换结果句柄，供保存使用

  const setStatus = (text) => { statusEl.textContent = text; };

  // 握手：确认协议版本与已批准能力
  async function boot() {
    try {
      const info = await window.InformetionBridge.handshake(['file.pick', 'file.read', 'file.save']);
      setStatus(`已连接宿主：uiBridge ${info.uiBridge}，平台 ${info.platform}`);
    } catch (error) {
      setStatus(`握手失败：${error.message}`);
    }
  }

  // 选择归档 → 调用自己的服务 → 读取结果句柄预览
  pickBtn.onclick = async () => {
    pickBtn.disabled = true;
    try {
      const picked = await window.InformetionBridge.rpc('host.file.pick', { purpose: '选择要转换的聊天归档' });
      setStatus(`已选择 ${picked.name}（${picked.size} 字节）`);

      const called = await window.InformetionBridge.rpc('host.service.call', {
        service: 'document.convert',
        versionRange: '^1.0.0',
        input: { source: `resource:${picked.handle}`, targetFormat: formatEl.value },
      });

      let task = await window.InformetionBridge.rpc('host.task.get', { taskId: called.taskId });
      for (let i = 0; task.state === 'queued' || task.state === 'running'; i++) {
        if (i > 100) throw new Error('等待任务超时');
        await new Promise((resolve) => setTimeout(resolve, 20));
        task = await window.InformetionBridge.rpc('host.task.get', { taskId: called.taskId });
      }
      if (task.state !== 'succeeded') throw new Error(`任务未成功：${task.state}`);

      resultHandle = task.output.result;
      const chunk = await window.InformetionBridge.rpc('host.resource.read', { handle: task.output.result.replace('resource:', ''), offset: 0 });
      previewEl.value = new TextDecoder().decode(Uint8Array.from(atob(chunk.bytes), (c) => c.charCodeAt(0)));
      saveBtn.disabled = false;
      setStatus(`转换完成，共 ${task.output.messageCount} 条消息。`);
    } catch (error) {
      setStatus(`转换失败：${error.message}（${error.code || 'UNKNOWN'}）`);
    } finally {
      pickBtn.disabled = false;
    }
  };

  // 保存：只提交结果句柄，输出位置由宿主决定
  saveBtn.onclick = async () => {
    try {
      const saved = await window.InformetionBridge.rpc('host.file.save', {
        handle: resultHandle.replace('resource:', ''),
        suggestedName: `chat-export.${formatEl.value === 'markdown' ? 'md' : formatEl.value}`,
      });
      setStatus(`已保存：${saved.label}`);
    } catch (error) {
      setStatus(`保存失败：${error.message}（${error.code || 'UNKNOWN'}）`);
    }
  };

  boot();
})();

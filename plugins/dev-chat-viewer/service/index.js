// 文件职责：查看器插件提供的 archive.export 服务实现——演示插件之间通过宿主服务契约互通
'use strict';

const { createBridge } = require('./host-rpc.js');

// 读取宿主签发的资源句柄（分块读取，与宿主 256 KiB 上限一致）
async function readResource(ctx, handleRef) {
  const handleId = String(handleRef).replace(/^resource:/, '');
  const parts = [];
  let offset = 0;
  for (;;) {
    const chunk = await ctx.callHost('host.resource.read', { handle: handleId, offset, length: 262144 });
    parts.push(Buffer.from(chunk.bytes, 'base64'));
    if (chunk.eof) break;
    offset = chunk.nextOffset;
  }
  return Buffer.concat(parts).toString('utf8');
}

// 等待任务进入终态；M1 的服务通常立即完成，但语义上仍按异步处理
async function waitForTask(ctx, taskId, maxRounds) {
  for (let round = 0; round < maxRounds; round++) {
    const task = await ctx.callHost('host.task.get', { taskId });
    if (task.state === 'succeeded') return task;
    if (task.state === 'failed' || task.state === 'cancelled') {
      const err = new Error(`下游服务未成功：${task.state} ${(task.error && task.error.message) || ''}`);
      err.code = task.state === 'cancelled' ? 'CANCELLED' : 'PROVIDER_UNAVAILABLE';
      throw err;
    }
    if (ctx.isCancelled(ctx.callId)) {
      await ctx.callHost('host.task.cancel', { taskId });
      const err = new Error('调用方已取消');
      err.code = 'CANCELLED';
      throw err;
    }
    await new Promise((resolve) => setTimeout(resolve, 20)); // 演示用短轮询
  }
  const err = new Error('等待下游任务超时');
  err.code = 'TIMEOUT';
  throw err;
}

// 服务实现表：archive.export 自身不实现转换，而是复用已绑定的 document.convert
const services = {
  'archive.export': async (input, ctx) => {
    if (!input.source || !input.targetFormat) {
      const err = new Error('缺少 source 或 targetFormat 参数');
      err.code = 'CONTRACT_MISMATCH';
      throw err;
    }

    // 1. 通过宿主调用已绑定的转换服务；调用方身份与资源派生都由宿主完成
    const called = await ctx.callHost('host.service.call', {
      service: 'document.convert',
      versionRange: '^1.0.0',
      input: { source: input.source, targetFormat: input.targetFormat },
    });

    // 2. 读取任务终态：task.output.result 是宿主派生给本插件的只读句柄
    const task = await waitForTask(ctx, called.taskId, 100);
    const binding = await ctx.callHost('host.binding.get', { service: 'document.convert' });

    // 3. 读取结果句柄，把正文回传给本服务的调用方
    const body = await readResource(ctx, task.output.result);
    return {
      result: body,
      mediaType: task.output.mediaType || 'text/markdown',
      messageCount: task.output.messageCount || 0,
      convertedBy: binding.providerInstallationId,
    };
  },
};

createBridge({ services });

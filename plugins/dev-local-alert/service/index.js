// 文件职责：本地测试提醒插件的服务实现——按登记类别发布事件，实际等级由宿主决定
'use strict';

const { createBridge } = require('./host-rpc.js');

// 服务实现表：只负责提交请求，不自行判断是否"紧急"
const services = {
  'alert.notify-test': async (input, ctx) => {
    if (!input.category || !input.eventId || !input.title || !input.body) {
      const err = new Error('缺少 category / eventId / title / body');
      err.code = 'CONTRACT_MISMATCH';
      throw err;
    }

    // 有效期：紧急事件必须有过期时间，宿主上限 5 分钟
    const ttl = Math.min(Math.max(input.expiresInSeconds || 60, 1), 300);
    const now = new Date();
    const expiresAt = new Date(now.getTime() + ttl * 1000).toISOString();

    // 提交到宿主；注意请求里不带 sourceId，来源由宿主安装记录生成
    const result = await ctx.callHost('host.notification.publish', {
      category: input.category,
      eventId: input.eventId,
      revision: input.revision || 1,
      requestedLevel: input.requestedLevel || 'normal',
      title: input.title,
      body: input.body,
      occurredAt: now.toISOString(),
      expiresAt,
    });

    return {
      notificationId: result.notificationId,
      effectiveLevel: result.effectiveLevel,
      state: result.state,
      reason: result.reason,
    };
  },
};

createBridge({ services });

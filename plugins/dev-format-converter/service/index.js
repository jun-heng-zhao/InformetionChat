// 文件职责：格式转换插件提供的 document.convert 服务实现（演示用运行时入口）
// 说明：演示阶段由宿主的子进程运行时执行本文件；接入 WebView 后同一份业务逻辑移入 UI 进程
'use strict';

const { createBridge } = require('./host-rpc.js');

// 读取宿主签发的资源句柄：分块读取，每块最多 256 KiB（与宿主上限一致）
async function readResource(ctx, handleRef) {
  const handleId = String(handleRef).replace(/^resource:/, '');
  const parts = [];
  let offset = 0;
  for (;;) {
    if (ctx.isCancelled(ctx.callId)) {
      const err = new Error('调用方已取消');
      err.code = 'CANCELLED';
      throw err;
    }
    const chunk = await ctx.callHost('host.resource.read', { handle: handleId, offset, length: 262144 });
    parts.push(Buffer.from(chunk.bytes, 'base64'));
    if (chunk.eof) break;
    offset = chunk.nextOffset;
  }
  return Buffer.concat(parts).toString('utf8');
}

// 校验标准归档结构：字段不合法时按契约不匹配上报，而不是产出错误的转换结果
function parseArchive(text) {
  let archive;
  try {
    archive = JSON.parse(text);
  } catch (e) {
    const err = new Error('输入不是合法 JSON 归档');
    err.code = 'CONTRACT_MISMATCH';
    throw err;
  }
  if (!archive || !Array.isArray(archive.messages)) {
    const err = new Error('归档缺少 messages 数组');
    err.code = 'CONTRACT_MISMATCH';
    throw err;
  }
  return archive;
}

// 转义 Markdown 正文里可能干扰结构的字符，避免内容被当作格式指令执行
function escapeMarkdown(text) {
  return String(text == null ? '' : text).replace(/([\\`*_{}[\]()#+\-.!|>])/g, '\\$1');
}

// 归档 → Markdown；标题行保留来源与时间，便于人工核对
function toMarkdown(archive) {
  const lines = [`# ${archive.title || '聊天归档'}`, ''];
  for (const message of archive.messages) {
    const author = message.authorId || 'unknown';
    const at = message.createdAt || '';
    lines.push(`## ${escapeMarkdown(author)} · ${at}`);
    lines.push('');
    lines.push(escapeMarkdown(message.body));
    lines.push('');
  }
  return lines.join('\n');
}

// 服务实现表：服务 ID 必须与 manifest 中 services.provides 一致
const services = {
  'document.convert': async (input, ctx) => {
    if (!input.source) {
      const err = new Error('缺少 source 参数');
      err.code = 'CONTRACT_MISMATCH';
      throw err;
    }
    if (input.targetFormat !== 'markdown') {
      const err = new Error(`本版只支持 markdown，收到：${input.targetFormat}`);
      err.code = 'CONTRACT_MISMATCH';
      throw err;
    }
    const archive = parseArchive(await readResource(ctx, input.source));
    const markdown = toMarkdown(archive);
    return {
      result: markdown,                        // 宿主会把 result 存成临时资源句柄
      mediaType: 'text/markdown',
      messageCount: archive.messages.length,
    };
  },
};

createBridge({ services });
